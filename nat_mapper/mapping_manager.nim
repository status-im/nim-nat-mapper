import std/sequtils
import pkg/[
    chronos,
    chronicles
  ]

import ./tinyupnp

when (NimMajor, NimMinor) < (1, 4):
  {.push raises: [Defect].}
else:
  {.push raises: [].}

logScope: topics = "nat_mapping_manager"

type
  PortMapping* = object
    port*: int
    protocol*: NatProtocolType

  MappingManager* = ref object
    mappings: seq[PortMapping]
    upnpSession: TUpnpSession
    agent*: string
    mappingFrequency: Duration
    refreshLoop: Future[void]

proc toUpnp(manager: MappingManager, pm: PortMapping): TUpnpPortMapping =
  TUpnpPortMapping(
    externalPort: pm.port,
    internalPort: pm.port,
    internalClient: manager.upnpSession.localIp,
    protocol: pm.protocol,
    description: manager.agent,
    leaseDuration: manager.mappingFrequency
  )

proc removeMappings*(manager: MappingManager, pms: seq[PortMapping]) {.async.} =
  for mapping in pms:
    if mapping in manager.mappings:
      await manager.upnpSession.deletePortMapping(manager.toUpnp(mapping))

  manager.mappings.keepItIf(it notin pms)

  let allMappings = await manager.upnpSession.getAllMappings()
  for mapping in pms:
    let asUpnp = manager.toUpnp(mapping)
    if allMappings.anyIt(it.same(asUpnp)):
      # Nothing we can really do here except ringing the alarm
      info "Can't delete upnp mapping!", mapping

proc removeAllMappings*(manager: MappingManager) {.async.} =
  await manager.removeMappings(manager.mappings)

proc refreshMappings(manager: MappingManager) {.async.} =
  for mapping in manager.mappings:
    await manager.upnpSession.addPortMapping(manager.toUpnp(mapping))

proc refreshLoop(manager: MappingManager) {.async.} =
  while true:
    await sleepAsync(manager.mappingFrequency - 30.seconds)
    try:
      #TODO notify that our ip changed somehow
      discard await manager.upnpSession.check()
      await manager.refreshMappings()
    except CatchableError as exc:
      warn "Failed to refresh mappings!", err=exc.msg

proc setup*(manager: MappingManager) {.async.} =
  if isNil(manager.upnpSession):
    manager.upnpSession = TUpnpSession.new()
    await manager.upnpSession.setup()

proc stop*(manager: MappingManager) {.async.} =
  if not isNil(manager.refreshLoop):
    await manager.removeAllMappings()
    manager.refreshLoop.cancel()
    manager.refreshLoop = nil

proc publicIp*(manager: MappingManager): Future[IpAddress] {.async.} =
  await manager.setup()
  return manager.upnpSession.publicIp

proc addMappings*(manager: MappingManager, pms: seq[PortMapping]) {.async.} =
  await manager.setup()

  for pm in pms:
    if pm notin manager.mappings:
      manager.mappings.add(pm)

  await manager.refreshMappings()

  if manager.mappings.len > 0 and isNil(manager.refreshLoop):
    manager.refreshLoop = refreshLoop(manager)
  elif manager.mappings.len == 0:
    await manager.stop()

proc addMapping*(manager: MappingManager, pm: PortMapping) {.async.} =
  await manager.addMappings(@[pm])

proc new*(
  T: type[MappingManager],
  frequency = 20.minutes,
  agent = "nim upnp"): T =

  doAssert frequency > 50.seconds
  T(
    agent: agent,
    mappingFrequency: frequency
  )

when isMainModule:
  let manager = MappingManager.new(frequency = 1.minutes)
  waitFor manager.addMapping(PortMapping(port: 55551, protocol: Tcp))
  waitFor sleepAsync(3.minutes)
  waitFor manager.removeAllMappings()
  waitFor sleepAsync(2.minutes)

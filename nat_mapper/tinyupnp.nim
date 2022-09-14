import std/[strutils, options, sequtils, uri, sets, tables]
import std/[xmltree, xmlparser]
import pkg/[
    chronos, chronos/apps/http/httpclient,
    stew/byteutils,
    chronicles
  ]

import ./common
export common

logScope:
  topics = "tinyupnp"

const
  upnpServiceTypes = @[
    "urn:schemas-upnp-org:device:InternetGatewayDevice:1",
    "urn:schemas-upnp-org:device:InternetGatewayDevice:2",
    "urn:schemas-upnp-org:service:WANIPConnection:1",
    "urn:schemas-upnp-org:service:WANIPConnection:2",
    "urn:schemas-upnp-org:service:WANPPPConnection:1"
  ]

let
  ssdpMulticast = initTAddress("239.255.255.250", 1900)

type
  TUpnpPortMapping* = object
    externalPort*, internalPort*: int
    internalClient*: IpAddress
    protocol*: NatProtocolType
    description*: string
    leaseDuration*: Duration

  TUpnpGateway = object
    controlUri: Uri
    serviceType: string
    localIp: IpAddress

  TUpnpSession* = ref object
    discoveryTransp: DatagramTransport
    triedPages: HashSet[string]
    gateway: TUpnpGateway
    gatewayFound: Future[void]
    publicIp: IpAddress

proc publicIp*(sess: TUpnpSession): IpAddress =
  sess.publicIp

proc localIp*(sess: TUpnpSession): IpAddress =
  sess.gateway.localIp

proc same*(a, b: TUpnpPortMapping): bool =
  a.externalPort == b.externalPort and
  a.internalPort == b.internalPort and
  a.protocol == b.protocol and
  a.internalClient == b.internalClient

# Soap
type
  SoapResponse = object
    status: int
    body: string
    response: Table[string, string]
    xmlTree: XmlNode
    localIp: IpAddress

proc postSoap(uri: Uri, body, soapAction: string): Future[SoapResponse] {.async.} =
  let
    session = HttpSessionRef.new()
    headers = [
            ("Content-Type", "text/xml; charset=utf-8"),
            ("SOAPAction", "\"" & soapAction & "\"")
            ]
    request = HttpClientRequestRef.new(session,
                session.getAddress(uri).tryGet(),
                MethodPost,
                headers = headers,
                body = body.toBytes())
    res = await request.send()

  result.localIp = res.connection.transp.localAddress().address()
  result.body = string.fromBytes(await res.getBodyBytes())
  result.status = res.status
  await res.closeWait()
  await request.closeWait()
  await session.closeWait()

proc getAllRecur(node: XmlNode, tag: string): seq[XmlNode] =
  for child in node:
    if child.kind == xnElement:
      if cmpIgnoreCase(child.tag, tag) == 0:
        result.add child
      result &= child.getAllRecur(tag)

proc `[]`(node: XmlNode, tag: string): XmlNode =
  if isNil(node): return nil
  if node.kind == xnElement:
    for child in node:
      if child.kind == xnElement and cmpIgnoreCase(child.tag, tag) == 0:
        return child

proc getStr(node: XmlNode): string =
  if isNil(node): ""
  elif node.kind == xnElement and node.len == 1:
    node[0].getStr()
  elif node.kind == xnText:
    node.text
  else: ""

proc generateSoapEnveloppe(actionName, actionPath: string, args: Table[string, string]): string =
  let envelopeAttrs =
    {"s:encodingStyle": "http://schemas.xmlsoap.org/soap/encoding/",
     "xmlns:s": "http://schemas.xmlsoap.org/soap/envelope/"}.toXmlAttributes

  var action = newElement("u:" & actionName)
  action.attrs = {"xmlns:u": actionPath}.toXmlAttributes

  for argKey, argVal in args:
    let param = newElement(argKey)
    param.add newText(argVal)
    action.add(param)
  let
    tree = newXmlTree("s:Envelope", [
        newXmlTree("s:Body", [
          action
        ])
      ],
    envelopeAttrs)
  result = xmlHeader & $tree

proc soapRequest(gateway: TUpnpGateway, actionName: string, args = initTable[string, string]()): Future[SoapResponse] {.async.} =
  let request = generateSoapEnveloppe(actionName, gateway.serviceType, args)
  result = await postSoap(gateway.controlUri, request, gateway.serviceType & "#" & actionName)

  try:
    result.xmlTree = parseXml(result.body)["s:Body"]
    if not isNil(result.xmlTree):
      result.xmlTree = result.xmlTree[0]

      for child in result.xmlTree:
        result.response[child.tag.toLower()] = child.getStr()
  except XmlError as exc:
    trace "Cannot parse response XML", resp = result.body
  return result

# UPNP
proc addPortMapping*(tupnp: TUpnpSession, mapping: TUpnpPortMapping) {.async.} =
  debug "Adding port mapping", mapping
  let res = await soapRequest(tupnp.gateway, "AddPortMapping",
      {"NewRemoteHost": "",
      "NewExternalPort": $mapping.externalPort,
      "NewInternalPort": $mapping.internalPort,
      "NewInternalClient": $mapping.internalClient,
      "NewProtocol": if mapping.protocol == Tcp: "TCP" else: "UDP",
      "NewEnabled": "1",
      "NewPortMappingDescription": mapping.description,
      "NewLeaseDuration": $mapping.leaseDuration.seconds,
       }.toTable()
    )

proc deletePortMapping*(tupnp: TUpnpSession, mapping: TUpnpPortMapping) {.async.} =
  debug "Deleting port mapping", mapping
  let res = await soapRequest(tupnp.gateway, "DeletePortMapping",
    {
      "NewRemoteHost": "",
      "NewExternalPort": $mapping.externalPort,
      "NewProtocol": if mapping.protocol == Tcp: "TCP" else: "UDP",
       }.toTable()
    )

proc getAllMappings*(tupnp: TUpnpSession): Future[seq[TUpnpPortMapping]] {.async.} =
  debug "Getting all mappings"
  for i in 0..50:
    let res = await soapRequest(tupnp.gateway,
      "GetGenericPortMappingEntry", {"NewPortMappingIndex": $i}.toTable())

    if "newinternalport" notin res.response: break

    result.add TUpnpPortMapping(
       externalPort: parseInt(res.response.getOrDefault("newexternalport")),
       internalPort: parseInt(res.response.getOrDefault("newinternalport")),
       internalClient: parseIpAddress(res.response.getOrDefault("newinternalclient")),
       protocol: if res.response.getOrDefault("newinternalclient") == "TCP": Tcp else: Udp,
       description: res.response.getOrDefault("newportmappingdescription"),
       leaseDuration: parseInt(res.response.getOrDefault("newleaseduration")).seconds
    )

proc getIps(gateway: TUpnpGateway): Future[(IpAddress, IpAddress)] {.async.} =
  let
    extIpSoapResp = await soapRequest(gateway, "GetExternalIPAddress")
    extIp = parseIpAddress(extIpSoapResp.response.getOrDefault("newexternalipaddress"))
  return (extIpSoapResp.localIp, extIp)

proc retrievePage(uri: Uri): Future[string] {.async.} =
  let session = HttpSessionRef.new()
  let resp = await session.fetch(uri)
  await session.closeWait()
  return string.fromBytes(resp.data)

proc tryGatewayLocation(tupnp: TUpnpSession, location: Uri) {.async.} =
  if $location in tupnp.triedPages: return
  tupnp.triedPages.incl $location
  logScope: location
  debug "Trying gateway location"
  let
    page = await retrievePage(location)
    pageXml =
      try: parseXml(page)
      except XmlError as exc:
        debug "Can't decode XML from location", err = exc.msg
        return

  for service in pageXml.getAllRecur("service"):

    # another gateway was found before us
    if tupnp.gatewayFound.finished: return

    let serviceType = service["serviceType"].getStr()
    logScope: serviceType
    let formattedServiceTypes =
      upnpServiceTypes.filterIt(it.toLower() == serviceType.toLower())

    if formattedServiceTypes.len == 0:
      trace "Service type not in allowed list"
      continue

    let
      formattedServiceType = formattedServiceTypes[0]

    let controlUrl = service["controlUrl"].getStr()

    if controlUrl.len == 0:
      trace "Cannot find control url"
      continue

    var gatewayCandidate = TUpnpGateway(
      controlUri: location,
      serviceType: formattedServiceType
    )
    gatewayCandidate.controlUri.path = controlUrl

    let ips =
      try:
        await gatewayCandidate.getIps()
      except CatchableError as exc:
        trace "Cannot retrieve public IP from gateway", msg=exc.msg
        continue

    # another gateway was found before us
    if tupnp.gatewayFound.finished: return

    tupnp.publicIp = ips[1]
    gatewayCandidate.localIp = ips[0]
    info "Found suitable gateway", controlUri = gatewayCandidate.controlUri,
      localIp = gatewayCandidate.localIp
    tupnp.gateway = gatewayCandidate
    tupnp.gatewayFound.complete()
    return

#SSDP (discovery)
proc received(tupnp: TUpnpSession) {.async.} =
  const locationAnchor = "\r\nLOCATION:"
  let
    data = string.fromBytes(tupnp.discoveryTransp.getMessage())
    dataUpper = data.toUpper()
  if dataUpper.startsWith("HTTP/1.1 200 OK"):
    let foundAnchor = dataUpper.find(locationAnchor)
    if foundAnchor >= 0:
      if upnpServiceTypes.anyIt(it in data):
        let location = data[foundAnchor + locationAnchor.len .. ^1].split("\r\n", 1)[0]
        await tupnp.tryGatewayLocation(parseUri(location.strip()))
      else:
        trace "SSDP response with useless service type", response = data
    else:
      trace "SSDP response with invalid Location", response = data
  else:
    trace "SSDP response without 200 OK", response = data

proc broadastMSearch(tupnp: TUpnpSession) {.async.} =
  trace "Broadcasting MSearches"
  for possibleSt in upnpServiceTypes:
    let body = @[
      "M-SEARCH * HTTP/1.1",
      "HOST: 239.255.255.250:1900",
      "MAN: \"ssdp:discover\"",
      "ST: " & possibleSt,
      "MX: 2",
      "\r\n"].join("\r\n")

    await tupnp.discoveryTransp.sendTo(ssdpMulticast, body)

proc setup*(sess: TUpnpSession) {.async.} =
  debug "Setting up upnp session"
  proc onData(discoveryTransp: DatagramTransport, dat: TransportAddress) {.async.} =
    await sess.received()
  sess.discoveryTransp = newDatagramTransport(onData)
  sess.gatewayFound = newFuture[void]("TUpnp Gateway")

  await sess.broadastMSearch()
  let foundGateway = await sess.gatewayFound.withTimeout(5.seconds)

  await sess.discoveryTransp.closeWait()

  if not foundGateway:
    info "Couldn't find upnp gateway in time"
    sess.gatewayFound.cancel()
    raise newException(AsyncTimeoutError, "Cannot find upnp gateway")

proc check*(sess: TUpnpSession): Future[bool] {.async.} =
  ## Check that the session is still working, or restarts it if required
  ## Returns true if the public ip or private ip changed

  let startIps = (sess.gateway.localIp, sess.publicIp)

  let currentIps =
    try:
      await sess.gateway.getIps()
    except CatchableError as exc:
      debug "Cannot retrieve IPs, restarting session", err=exc.msg

      # can fail
      await sess.setup()
      (sess.gateway.localIp, sess.publicIp)

  if currentIps != startIps:
    sess.gateway.localIp = currentIps[0]
    sess.publicIp = currentIps[1]
    return true
  return false

when isMainModule:
  let sess = TUpnpSession.new()
  waitFor(sess.setup())
  let newMapping = TUpnpPortMapping(
    externalPort: 5445, internalPort: 5445, internalClient: sess.gateway.localIp,
    protocol: Tcp, description: "test binding tinyupnp", leaseDuration: 5.minutes)

  waitFor sess.addPortMapping(newMapping)
  doAssert (waitFor sess.getAllMappings()).anyIt(it.same(newMapping))
  waitFor sess.deletePortMapping(newMapping)
  doAssert (waitFor sess.getAllMappings()).countIt(it.same(newMapping)) == 0

# Pure Nim NAT traversal

[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](https://opensource.org/licenses/MIT)
[![License: Apache](https://img.shields.io/badge/License-Apache%202.0-blue.svg)](https://opensource.org/licenses/Apache-2.0)
![Stability: experimental](https://img.shields.io/badge/stability-experimental-orange.svg)

NAT automated port mapping using UPnP for [chronos](https://github.com/status-im/nim-chronos).

### Troubleshooting
tinyupnp includes a quick test to see if it's working correctly:
```sh
$ nim -d:chronicles_log_level=TRACE c -r tinyupnp.nim
[..]
2022-09-14 17:20:07.224+02:00 Getting all mappings                       topics="tinyupnp"
$
```

With upnp disabled:
```sh
$ nim -d:chronicles_log_level=TRACE c -r tinyupnp.nim
[..]
TRC 2022-09-14 17:23:35.327+02:00 SSDP response with useless service type    topics="tinyupnp" tid=76330 response="HTTP/1.1 200 OK\r\nHOST: 239.255.255.250:1900\r\nEXT:\r\nCACHE-CONTROL: max-age=100\r\nLOCATION: http://192.168.1.10:80/description.xml\r\nSERVER: UPnP/1.0 IpBridge/1.52.0\r\nST: urn:schemas-upnp-org:device:basic:1\r\n\r\n"
INF 2022-09-14 17:23:36.289+02:00 Couldn't find upnp gateway in time
```

If upnp is enabled in your network and doesn't work with `tinyupnp`, please open an issue _without_ the logs as they may contain sensitive information!

### TODO

- [X] UPnP implementation
- [ ] Mapping manager
- [ ] NAT-PMP implementation

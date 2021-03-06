import options
from sequtils import zip
from strutils import replace, split
import strtabs, tables, base64, xmlparser, xmltree, streams
import uri, asyncdispatch, httpClient


type
  OperationFailed* = object of Exception

type
  filesTable = Table[string, string]
  header = tuple
    name: string
    value: string
  namespace = tuple
    name: string
    url: string

type
  Depth* = enum
    ZERO = "0"
    ONE = "1"
    INF = "infinity"


proc operationFailed*(msg: string) {.noreturn.} =
  ## raises an OperationFailed exception with message `msg`.
  var e: ref OperationFailed
  new(e)
  e.msg = msg
  raise e


type AsyncWebDAV* = ref object of RootObj
  client*: AsyncHttpClient
  path*: string
  address*: string
  username: string
  password: string


proc newAsyncWebDAV*(address: string, username: string, password: string,
                     path: string = ""): AsyncWebDAV =

  let fulladdr = parseUri(address) / path
  let client = newAsyncHttpClient()
  # client.headers["Authorization"] = "Basic " & base64.encode(
  #   username & ":" & password
  # )

  AsyncWebDAV(
    client: client,
    path: path,
    address: $fulladdr,
    username: username,
    password: password,
  )


proc request(
  wd: AsyncWebDAV,
  path: string,
  httpMethod: string,
  body: string = "",
  headers: Option[seq[header]] = none(seq[header]),
): Future[AsyncResponse] {.async.} =

  let auth = "Basic " & base64.encode(
    wd.username & ":" & wd.password
  )

  wd.client.headers = newHttpHeaders({"Authorization": auth})

  if isSome(headers):
    for (h, v) in headers.get:
      wd.client.headers[h] = v

  return await wd.client.request(
    $(parseUri(wd.address) / path),
    httpMethod = httpMethod,
    body = body
  )


proc ls*(
  wd: AsyncWebDAV,
  path: string,
  props: Option[seq[string]] = none(seq[string]),
  namespaces: Option[seq[namespace]] = none(seq[namespace]),
  depth: Depth = INF,
): Future[Table[string, filesTable]] {.async.} =

  var propNode = newElement("prop")
  var nsAttrs = {"xmlns": "DAV:"}.toXmlAttributes

  if isSome(namespaces):
    for (ns, url) in namespaces.get:
      nsAttrs["xmlns:" & ns] = url

  var reqBody = ""

  if isSome(props):
    for p in props.get:
      let pNode = newElement(p)
      propNode.add(pNode)

    var reqXml = newElement("propfind")
    reqXml.attrs = nsAttrs
    reqXml.add(propNode)

    reqBody = "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n" & $reqXml

  let resp = await wd.request(
    path,
    httpMethod = "PROPFIND",
    body = reqBody,
    headers = some(@[("Depth", $depth)])
  )

  if resp.code != HttpCode(207):
    operationFailed("Got unexpected response from server:\n" & await resp.body)

  let body = await resp.body
  let node: XmlNode = parseXml(body)
  var files = initTable[string, filesTable]()
  var hrefs = newSeq[string]()
  var propsTables = newSeq[filesTable]()

  let NS = node.tag.split(":")[0] & ":"

  for item in node:
    let href = item.child(NS & "href")
    let props = item.child(NS & "propstat")
    hrefs.add(href.innerText.replace(wd.path, ""))

    var propsTable: filesTable
    for prop in props.findAll(NS & "prop"):
      for p in prop:
        propsTable[p.tag] = p.innerText

    propsTables.add(propsTable)

  for pairs in zip(hrefs, propsTables):
    let (href, props) = pairs
    files[href] = props

  return files

proc download*(
  wd: AsyncWebDAV,
  path: string,
  destination: string,
) {.async.} =
  let resp = await wd.request(
    path,
    httpMethod = "GET",
  )

  if resp.code != HttpCode(200):
    operationFailed(await resp.body)

  var output = newFileStream(destination, fmWrite)

  if not isNil(output):
    output.write(await resp.body)
    output.close()


proc upload*(
  wd: AsyncWebDAV,
  filepath: string,
  destination: string,
) {.async.} =
  var strm = newFileStream(filepath, fmRead)

  if isNil(strm):
    operationFailed("File \"" & filepath & "\" not found")

  let reqBody = strm.readAll()

  let resp = await wd.request(
    destination,
    httpMethod = "PUT",
    body = reqBody,
  )

  if resp.code != HttpCode(201):
    operationFailed(await resp.body)


proc mkdir*(
  wd: AsyncWebDAV,
  path: string,
) {.async.} =
  let resp = await wd.request(
    path,
    httpMethod = "MKCOL",
  )

  if resp.code != HttpCode(201):
    operationFailed(await resp.body)


proc rm*(
  wd: AsyncWebDAV,
  path: string,
) {.async.} =

  let resp = await wd.request(
    path,
    httpMethod = "DELETE",
  )

  if resp.code != HttpCode(204):
    operationFailed(await resp.body)


proc mv*(
  wd: AsyncWebDAV,
  path: string,
  destination: string,
  overwrite: bool = false,
  depth: Depth = INF,
) {.async.} =
  var overwriteValue = "F"
  if overwrite:
    overwriteValue = "T"

  let resp = await wd.request(
    path,
    httpMethod = "MOVE",
    headers = some(
      @[("Destination", $(parseUri(wd.address) / destination)),
        ("Overwrite", overwriteValue),
        ("Depth", $depth)]
    )
  )

  if resp.code != HttpCode(204) and resp.code != HttpCode(201):
    operationFailed(await resp.body)


proc cp*(
  wd: AsyncWebDAV,
  path: string,
  destination: string,
  overwrite: bool = false,
  depth: Depth = INF,
) {.async.} =
  var overwriteValue = "F"
  if overwrite:
    overwriteValue = "T"

  let resp = await wd.request(
    path,
    httpMethod = "COPY",
    headers = some(
      @[("Destination", $(parseUri(wd.address) / destination)),
        ("Overwrite", overwriteValue),
        ("Depth", $depth)]
    )
  )

  if resp.code != HttpCode(204) and resp.code != HttpCode(201):
    operationFailed(await resp.body)

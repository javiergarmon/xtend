stream = require('stream')
request = require('request')
fs = require('fs')
dp = require('eyes').inspector(maxLength: 20000)
zlib = require 'zlib'
CookieHandler = require('./cookie_handler')
BufferStream = require('bufferstream')

BINARY = 1
JS = 2
HTML = 3

fileIndex = 0

# we buffer up all the data if it's html or js, then send
# all that data to the client.  I guess if we're
# sophisticated, we could rewrite & stream the html on
# every closing bracket.
#
# we don't manipulate binary content right now, we just
# pass it along to the response object immediately
class ProxyStream extends stream.Stream
  writable: true
  constructor: (req, res, guide, isScript, protocol, skip) ->
    @g = guide
    @type = BINARY
    @skip = skip
    @protocol = protocol
    @host = req.headers.host
    @isScript = isScript
    if @isScript
      @type = JS
    @proxiedHost = @g.xtnd.toProxiedHost(@host)
    @res = res
    @req = req

  _setContentType: (value) ->
    unless @skip
      if value?.match(/html/i)
        @type = HTML
      else if @isScript || value?.match(/javascript/i)
        @type = JS

  setSessionId: (id) ->
    @sessionId = id
    @req.session.sessionId = id

  setRequestCookies: (cookieString) ->
    if cookieString
      @requestHeaders['cookie'] = cookieString
    else
      delete @requestHeaders['cookie']


  setResponseCookies: (cookies) ->
    # if cookies?.length > 0
      # dp "using these cookies in client response for #{@host}"
      # dp cookies
      # @res.setHeader('set-cookie', cookies)

  process: (next) ->
    @requestHeaders = {}
    for own k,v of @req.headers
      do (k,v) =>
        val = @visitRequestHeader(k?.toLowerCase(), v)
        if val
          @requestHeaders[k] = val
    @cook = new CookieHandler(@req.session.id, @req.cookies, @)
    @cook.processRequest =>
      if @g.DEBUG_REQ_HEADERS
        console.log('Request headers --------->>>')
        dp(@requestHeaders)
      next()

  pipefilter: (resp, dest) ->
    if @g.DEBUG_RES_HEADERS
      console.log('Unmodified Response headers <<<---------')
      dp(resp.headers)
    for own k,v of resp.headers
      do (k,v) =>
        val = @visitResponseHeader(k, v)
        if val
          @res.setHeader(k, val)
        else
          @res.removeHeader(k)
    @res.statusCode = resp.statusCode
    @res.removeHeader('set-cookie')
    @cook.processResponse(resp.headers['set-cookie'])
    if @g.DEBUG_RES_HEADERS
      console.log('Response headers <<<---------')
      dp(@res._headers)
    @choosePipe()

  visitResponseHeader: (name, value) ->
    lowered = name.toLowerCase()
    switch lowered
      when 'content-encoding'
        if value?.match(/(gzip|deflate)/i)
          @compressed = true
      when 'location'
        return @g.xtnd.proxiedUrl(value)
      when 'access-control-allow-origin'
        return @g.xtnd.proxiedUrl(value)
      when 'content-type'
        @_setContentType(value)
        if @type == JS || @type == HTML
          @res.removeHeader('content-length')
      when 'x-frame-options'
        return null
      when 'content-length'
        if @type == JS || @type == HTML
          return null
    return value

  visitRequestHeader: (name, value) ->
    switch name
      when 'connection'
        return 'close'
      when 'origin'
        return @g.xtnd.normalUrl(value)
      when 'referer'
        return @g.xtnd.normalUrl(value)
    return value

  choosePipe: ->
    if @type == JS || @type == HTML
      if @compressed
        # if the stream came in compressed, we'll send it back out
        # compressed
        @res.setHeader('X-Pipe', 'compressed')
        buffer = new BufferStream()
        stream = new ContentStream(@req, @res, @type, @g, buffer)
        @pipe(zlib.createGunzip()).pipe(buffer)
        buffer.pipe(stream)
        stream.pipe(zlib.createGzip()).pipe(@res)
      else
        @res.setHeader('X-Pipe', 'content')
        buffer = new BufferStream()
        stream = new ContentStream(@req, @res, @type, @g, buffer)
        @pipe(buffer)
        buffer.pipe(stream)
        stream.pipe(@res)
    else
      @res.setHeader('X-Pipe', 'passthrough')
      @pipe(@res)

  write: (chunk, encoding) ->
    @emit 'data', chunk

  end: ->
    @emit 'end'

# TODO: Save html output into files for debugging later....
class ContentStream extends stream.Stream
  writable: true
  constructor: (req, res, type, guide, buffer) ->
    @type = type
    @g = guide
    @res = res
    @req = req
    @list = []
    @buffer = buffer
    if @type == JS
      @res.header('X-Pipe-Content', 'javascript')
    else if @type == HTML
      @htmlStreamParser = @g.createHtmlParser(@req.headers.host + '---' + @req.originalUrl)
      @res.header('X-Pipe-Content', 'html')

  write: (chunk, encoding) ->
    if @type == HTML
      @buffer.pause()
      if @g.DEBUG_OUTPUT_HTML && chunk.length > 0
        unless @debugfile
          url = @req.headers.host + @req.url
          fileIndex = fileIndex + 1
          @debugfile = fs.openSync("./debug/html#{fileIndex}.html", 'w+')
          fs.writeSync(@debugfile, "<!-- #{url} -->")
        fs.writeSync(@debugfile, chunk.toString())
      # we'll stream the html
      output = @htmlStreamParser(chunk.toString())
      if output.length != 0
        @emit 'data', output
      @buffer.resume()
    else
      @list.push(chunk.toString())

  end: (x) ->
    if @type == JS
      data = @list.join('')
      # if function/var is present in string, we assume JS
      # else, we will try to parse it with json and if it fails
      # go back to JS again
      if data.match(/(function|var)/)
        try
          output = @g.convertJs(data)
          @emit 'data', output
        catch e
          console.log('bad json:')
          console.log(data)
          @emit 'data', data
      else
        try
          JSON.parse(data)
          @emit 'data', data
        catch e
          try
            output = @g.convertJs(data)
            @emit 'data', output
          catch ee
            console.log('bad js:')
            console.log(data)
            @emit 'data', data
    @emit 'end'
    if @debugfile && @g.DEBUG_OUTPUT_HTML
      fs.closeSync(@debugfile)
module.exports = ProxyStream

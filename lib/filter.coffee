request = require('request')
express = require('express')
mongoose = require('mongoose')
ProxyStream = require('./proxy_stream')
BufferStream = require('bufferstream')
Session = require('connect-mongodb')
dp = require('eyes').inspector(maxLength: 50000)

# This is a connect module that performs the remote request if the url
# is not an "internal" url.
#
# Internal urls begin with a path like: /___xtnd
#
# All other requests have their data stream & headers sent to the remote
# server, after being slightly modified.
http = require('http')

module.exports = (options) ->
  guide = options.guide
  forceScriptSuffixRegExp = new RegExp(guide.FORCE_SCRIPT_SUFFIX, 'g')
  lastModifiedString = new Date().toString()
  protocol = options.protocol
  xtnd = guide.xtnd
  scripts = options.scripts
  cookieKey = options.cookieKey || 'xtnd.sid'
  cookieSecret = options.cookieSecret || 'blah blah you have to go there'
  mongoUrl = options.mongoUrl || 'mongodb://localhost/xtnd'
  mongoose.connect(mongoUrl)
  sessionFunc = express.session(
    key: cookieKey
    cookie:
      domain: '.'+guide.host
    secret: cookieSecret
    store: new Session(url: mongoUrl)
  )
  returnVal = (req, res, next) ->
    originalUrl = req.originalUrl
    sessionFunc req, res, ->
      subdomain = req.headers?.host?.split('.')[0]
      if req.url.indexOf(guide.INTERNAL_URL_PREFIX) != -1
        if req.url.match(/xtnd_scripts.js/)
          res.setHeader('Content-Type', 'text/javascript; charset=UTF-8')
          res.setHeader('Last-Modified', lastModifiedString)
          if typeof(scripts) == 'function'
            scripts(res)
          else
            res.send(scripts)
        else
          next()
      else if guide.LOCAL_SUBDOMAINS[subdomain]
        next()
      else if req.url == '/robots.txt'
        res.setHeader('Content-Type', 'text/plain; charset=utf-8')
        res.send("User-agent: *\nDisallow: /\n")
      else if req.method.toLowerCase() == 'options'
        res.setHeader('access-control-allow-credentials', 'true')
        res.setHeader('access-control-allow-origin', req.headers.origin)
        res.setHeader('content-type', 'text/plain')
        for own name,v of req.headers
          do (name,v) =>
            switch name.toLowerCase()
              when 'access-control-request-origin'
                res.setHeader('access-control-allow-origin', v)
              when 'access-control-request-method'
                res.setHeader('access-control-allow-methods', 'GET, PUT, DELETE, POST, OPTIONS')
              when 'access-control-request-headers'
                res.setHeader('access-control-allow-headers', v)
                res.setHeader('access-control-expose-headers', v)
              when 'access-control-request-credentials'
                res.setHeader('access-control-allow-credentials', 'true')
        res.send('')
      else
        buffer = new BufferStream()
        req.pipe(buffer)
        buffer.pause()
        isScript = false
        skip = false
        if originalUrl.indexOf(guide.FORCE_SCRIPT_SUFFIX) != -1
          originalUrl = originalUrl.replace(forceScriptSuffixRegExp, '')
          isScript = true
        if req.headers['x-xtnd-xhr']
          skip = true
        requestProtocol = req.headers['x-forwarded-proto'] || protocol
        url = xtnd.normalUrl(requestProtocol, req.headers.host, originalUrl)
        host = xtnd.toNormalHost(req.headers.host)
        if guide.isProxyUrl(host)
          res.send('')
          return
        req.headers.host = host
        stream = new ProxyStream(req, res, guide, isScript, protocol, skip, url)
        stream.process =>
          remoteReq = request(
            timeout: 5000
            url: url
            method: req.method
            followRedirect: false
            headers: stream.requestHeaders
            jar: false
            pipefilter: (resp, dest) -> stream.pipefilter(resp, dest)
          )
          # remoteReq.pause()
          remoteReq.pipe(stream)
          remoteReq.on 'end', (e) ->
            res.emit('complete')
          remoteReq.on 'close', (e) ->
            console.log('closed?', url)
          remoteReq.on 'error', (e) ->
            if e.code == 'ETIMEDOUT'
              console.log 'timeout 4 '+originalUrl
            else
              console.log('hmm... error')
          res.setHeader('X-Original-Url', host + req.originalUrl)
          buffer.on 'data', (chunk) ->
            remoteReq.write(chunk)
          buffer.on 'end', ->
            remoteReq.end()
          # remoteReq.resume()
          buffer.resume()

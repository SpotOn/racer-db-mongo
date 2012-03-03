{EventEmitter} = require 'events'
url = require 'url'
mongo = require 'mongodb'
NativeObjectId = mongo.BSONPure.ObjectID
query = require './query'

DISCONNECTED  = 1
CONNECTING    = 2
CONNECTED     = 3
DISCONNECTING = 4

module.exports = (racer) ->
  DbMongo::Query = query racer
  racer.adapters.db.Mongo = DbMongo

# Examples:
# new DbMongo
#   uri: 'mongodb://localhost:port/database'
# new DbMongo
#   host: 'localhost'
#   port: 27017
#   database: 'example'
DbMongo = (options) ->
  EventEmitter.call this
  @_loadConf options if options
  @_state = DISCONNECTED
  @_collections = {}
  @_pending = []

  # TODO Make version scale beyond 1 db
  #      by sharding and with a vector
  #      clock with each member the
  #      version of a shard
  # TODO Initialize the version properly upon web server restart
  #      so it's synced with the STM server (i.e., Redis) version
  @version = undefined

  return

DbMongo:: =
  __proto__: EventEmitter::

  _loadConf: (conf) ->
    if conf.uri
      uri = url.parse conf.uri
      @_host = uri.hostname
      @_port = uri.port || 27017
      # TODO callback
      @_database = uri.pathname.replace /\//g, ''
      [@_user, @_pass] = uri.auth?.split(':') ? []
    else
      {@_host, @_port, @_database, @_user, @_pass} = conf

  connect: (conf, callback) ->
    if typeof conf is 'function'
      callback = conf
    else if conf isnt undefined
      @_loadConf conf
    @_db ||= new mongo.Db(
        @_database
      , new mongo.Server @_host, @_port
    )
    @_state = CONNECTING
    @emit 'connecting'
    @_db.open (err) =>
      return callback err if err && callback
      open = =>
        @_state = CONNECTED
        @emit 'connected'
        for [method, args] in @_pending
          @[method].apply this, args
        @_pending = []

      if @_user && @_pass
        return @_db.authenticate @_user, @_pass, open
      return open()

  disconnect: (callback) ->
    collection._ready = false for _, collection of @_collections

    switch @_state
      when DISCONNECTED then callback null
      when CONNECTING
        @once 'connected', => @close callback
      when CONNECTED
        @_state = DISCONNECTING
        @_db.close()
        @_state = DISCONNECTED
        @emit 'disconnected'
        # TODO onClose callbacks for collections
        callback() if callback
      when DISCONNECTING then @once 'disconnected', -> callback null

  flush: (callback) ->
    return @_pending.push ['flush', arguments] if @_state != CONNECTED
    @_db.dropDatabase (err, done) -> callback err, done

  # Mutator methods called via CustomDataSource::applyOps
  update: (collection, conds, op, opts, callback) ->
    @_collection(collection).update conds, op, opts, callback

  findAndModify: (collection, conds, sort, op, opts, callback) ->
    @_collection(collection).findAndModify conds, sort, op, opts, callback

  insert: (collection, json, opts, callback) ->
    # TODO Leverage pkey flag; it may not be _id
    toInsert = Object.create json # So we have no side-effects in tests
    toInsert._id ||= new NativeObjectId
    @_collection(collection).insert toInsert, opts, (err) ->
      return callback err if err
      callback null, {_id: toInsert._id}

  remove: (collection, conds, callback) ->
    @_collection(collection).remove conds, (err) ->
      return callback err if err

  # Callback here receives raw json data back from Mongo
  findOne: (collection, conds, opts, callback) ->
    @_collection(collection).findOne conds, opts, callback

  find: (collection, conds, opts, callback) ->
    @_collection(collection).find conds, opts, (err, cursor) ->
      return callback err if err
      cursor.toArray (err, docs) ->
        return callback err if err
        return callback null, docs

  # Finds or creates the Mongo collection
  _collection: (name) ->
    @_collections[name] ||= new Collection name, @_db

  setVersion: (ver) -> @version = Math.max @version, ver

  setupDefaultPersistenceRoutes: (store) ->
    adapter = this

    idFor = (id) ->
      try
        return new NativeObjectId id
      catch e
        throw e unless e.message == 'Argument passed in must be a single String of 12 bytes or a string of 24 hex characters in hex format'
      return id

    store.defaultRoute 'get', '*.*.*', (collection, _id, relPath, done, next) ->
      only = {}
      only[relPath] = 1
      adapter.findOne collection, {_id}, only, (err, doc) ->
        return done err if err
        return done null, undefined, adapter.version if doc is null

        val = doc
        parts = relPath.split '.'
        val = val[prop] for prop in parts

        done null, val, adapter.version

    store.defaultRoute 'get', '*.*', (collection, _id, done, next) ->
      adapter.findOne collection, {_id}, {}, (err, doc) ->
        return done err if err
        return done null, undefined, adapter.version if doc is null
        delete doc.ver

        doc.id = doc._id.toString()
        delete doc._id

        done null, doc, adapter.version

    store.defaultRoute 'get', '*', (collection, done, next) ->
      adapter.find collection, {}, {}, (err, docs) ->
        return done err if err
        docsById = {}
        for doc in docs
          doc.id = doc._id.toString()
          delete doc._id
          delete doc.ver
          docsById[doc.id] = doc
        done null, docsById, adapter.version

    store.defaultRoute 'set', '*.*.*', (collection, _id, relPath, val, ver, done, next) ->
      (setTo = {})[relPath] = val
      op = $set: setTo
      _id = idFor _id
      adapter.findAndModify collection, {_id}, [['_id', 'asc']], op, upsert: true, (err, origDoc) ->
        return done err if err
        adapter.setVersion ver
        if Object.keys(origDoc).length
          origDoc.id = origDoc._id
          delete origDoc._id
          done null, origDoc
        else
          done null

    store.defaultRoute 'set', '*.*', (collection, _id, doc, ver, done, next) ->
      cb = (err) ->
        return done err if err
        adapter.setVersion ver
        done null
      if _id
        docCopy = {}
        for k, v of doc
          # Don't use `delete docCopy.id` so we avoid side-effects in tests
          docCopy[k] = v unless k is 'id'
        docCopy._id = _id = idFor _id
        adapter.findAndModify collection, {_id}, [['_id', 'asc']], docCopy, upsert: true, cb
      else
        adapter.insert collection, doc, {}, cb

    store.defaultRoute 'del', '*.*.*', (collection, _id, relPath, ver, done, next) ->
      (unsetConf = {})[relPath] = 1
      op = $unset: unsetConf
      op.$inc = {ver: 1}
      _id = idFor _id
      adapter.findAndModify collection, {_id}, [['_id', 'asc']], op, {}, (err, origDoc) ->
        return done err if err
        adapter.setVersion ver
        origDoc.id = origDoc._id
        delete origDoc._id
        done null, origDoc

    store.defaultRoute 'del', '*.*', (collection, _id, ver, done, next) ->
      adapter.findAndModify collection, {_id}, [['_id', 'asc']], {}, remove: true, (err, removedDoc) ->
        return done err if err
        adapter.setVersion ver
        removedDoc.id = removedDoc._id
        delete removedDoc._id
        done null, removedDoc

    store.defaultRoute 'push', '*.*.*', (collection, _id, relPath, vals..., ver, done, next) ->
      op = $inc: {ver: 1}
      if vals.length == 1
        (op.$push = {})[relPath] = vals[0]
      else
        (op.$pushAll = {})[relPath] = vals

      op.$inc = {ver: 1}

      _id = idFor _id
#      isLocalId = /^\$_\d+_\d+$/
#      if isLocalId.test _id
#        clientId = _id
#        _id = new NativeObjectId
#      else
#        _id = new NativeObjectId _id

      adapter.findAndModify collection, {_id}, [['_id', 'asc']], op, upsert: true, (err, origDoc) ->
        return done err if err
        adapter.setVersion ver
        origDoc.id = origDoc._id
        delete origDoc._id
        done null, origDoc
#        return done null unless clientId
#        idMap = {}
#        idMap[clientId] = _id
#        done null, idMap

    store.defaultRoute 'unshift', '*.*.*', (collection, _id, relPath, vals..., globalVer, done, next) ->
      opts = ver: 1
      opts[relPath] = 1
      _id = idFor _id
      exec = ->
        adapter.findOne collection, {_id}, opts, (err, found) ->
          return done err if err
          arr = found[relPath]?.slice() || []
          ver = found.ver
          arr.unshift vals...
          (setTo = {})[relPath] = arr
          op = $set: setTo, $inc: {ver: 1}
          adapter.update collection, {_id, ver}, op, {}, (err) ->
            throw err if err
            return exec() if err
            adapter.setVersion globalVer
            found.id = found._id
            delete found._id
            done null, found
      exec()

    store.defaultRoute 'insert', '*.*.*', (collection, _id, relPath, index, vals..., globalVer, done, next) ->
      opts = ver: 1
      opts[relPath] = 1
      _id = idFor _id
      do exec = ->
        adapter.findOne collection, {_id}, opts, (err, found) ->
          return done err if err
          arr = found[relPath]?.slice() || []
          arr.splice index, 0, vals...
          (setTo = {})[relPath] = arr
          op = $set: setTo, $inc: {ver: 1}
          ver = found.ver
          adapter.update collection, {_id, ver}, op, {}, (err) ->
            return exec() if err
            adapter.setVersion globalVer
            found.id = found._id
            delete found._id
            done null, found

    store.defaultRoute 'pop', '*.*.*', (collection, _id, relPath, ver, done, next) ->
      _id = idFor _id
      (popConf = {})[relPath] = 1
      op = $pop: popConf, $inc: {ver: 1}
      adapter.findAndModify collection, {_id}, [['_id', 'asc']], op, {}, (err, origDoc) ->
        return done err if err
        adapter.setVersion ver
        origDoc.id = origDoc._id
        delete origDoc._id
        done null, origDoc

    store.defaultRoute 'shift', '*.*.*', (collection, _id, relPath, globalVer, done, next) ->
      opts = ver: 1
      opts[relPath] = 1
      _id = idFor _id
      do exec = ->
        adapter.findOne collection, {_id}, opts, (err, found) ->
          return done err if err
          arr = found[relPath].slice?()
          return done null, found unless arr
          arr.shift()
          (setTo = {})[relPath] = arr
          op = $set: setTo, $inc: {ver: 1}
          ver = found.ver
          adapter.update collection, {_id, ver}, op, {}, (err) ->
            return exec() if err
            adapter.setVersion globalVer
            found.id = found._id
            delete found._id
            done null, found

    store.defaultRoute 'remove', '*.*.*', (collection, _id, relPath, index, count, globalVer, done, next) ->
      opts = ver: 1
      opts[relPath] = 1
      _id = idFor _id
      do exec = ->
        adapter.findOne collection, {_id}, opts, (err, found) ->
          return done err if err
          arr = found[relPath].slice?()
          done null, found unless arr
          arr.splice index, count
          (setTo = {})[relPath] = arr
          op = $set: setTo, $inc: {ver: 1}
          ver = found.ver
          adapter.update collection, {_id, ver}, op, {}, (err) ->
            return exec() if err
            adapter.setVersion globalVer
            found.id = found._id
            delete found._id
            done null, found

    store.defaultRoute 'move', '*.*.*', (collection, _id, relPath, from, to, count, globalVer, done, next) ->
      opts = ver: 1
      opts[relPath] = 1
      _id = idFor _id
      do exec = ->
        adapter.findOne collection, {_id}, opts, (err, found) ->
          return done err if err
          arr = found[relPath].slice?()
          done null, found unless arr
          to += arr.length if to < 0
          values = arr.splice from, count
          arr.splice to, 0, values...
          (setTo = {})[relPath] = arr
          op = $set: setTo, $inc: {ver: 1}
          ver = found.ver
          adapter.update collection, {_id, ver}, op, {}, (err) ->
            return exec() if err
            adapter.setVersion globalVer
            found.id = found._id
            delete found._id
            done null, found

MongoCollection = mongo.Collection

Collection = (name, db) ->
  @name = name
  @db = db
  @_pending = []
  @_ready = false

  db.collection name, (err, collection) =>
    throw err if err
    @_ready = true
    @collection = collection
    @onReady()

  return

Collection:: =
  onReady: ->
    for todo in @_pending
      @[todo[0]].apply this, todo[1]
    @_pending = []

for name, fn of MongoCollection::
  do (name, fn) ->
    Collection::[name] = ->
      collection = @collection
      args = arguments
      if @_ready
        process.nextTick ->
          collection[name].apply collection, args
      else
        @_pending.push [name, arguments]

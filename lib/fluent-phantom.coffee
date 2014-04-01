###
A fluent DSL for scraping web content using [PhantomJS](http://phantomjs.org/) 
and the [PhantomJS bridge for Node](https://github.com/sgentle/phantomjs-node).

###

# We require EventEmitter to be inherited by Request
Emitter = require('events').EventEmitter

# And we require our DSL grammar
Grammar = require('./builder-grammar')

# A simple helper to provide the time
now = ->
    (new Date).getTime()


# Classes are defined in a function to allow dependencies to be injected.
binder = (phantom) ->
    phantom = if typeof phantom == 'object' then phantom else require 'phantom'

    
    # A fluent builder
    class Builder extends Grammar.Sentence

        constructor: ->
            super()
            @properties = 
                conditions: []
                actions: []
                errorHandlers: []
                timeout: null
                url: null

        # Currying keeps access consistent - otherwise you'd have to use 
        # something like timeout.after(val) instead of timeout().after(val)
        # and timeout(val)
        timeout: (val) -> 
            obj = @_chunk new Grammar.Timeout @
            obj._push val
        
        forever: -> @timeout(0)

        extract: (val) -> 
            obj = @_chunk new Grammar.Extract @
            obj._push val

        select: (val) -> @extract val

        when: (val) ->
            obj = @_chunk new Grammar.WaitFor @
            obj._push val

        wait: (val) -> @when val

        from: (val) ->
            obj = @_chunk new Grammar.From @
            obj._push val

        url: (val) -> @from val

        otherwise: (val) ->
            obj = @_chunk new Grammar.Otherwise @
            obj._push val

        execute: (val) ->
            obj = @_chunk new Grammar.Execute @
            obj._push val

        do: (val) -> @execute val
        evaluate: (val) -> @execute val

        # Conditional synonym: until(1000) should be interpreted as setting
        # the request timeout to 1s, but until('selector') and until(->) should
        # be understood as synonymous with when().
        until: (arg) ->
            if typeof arg is 'number' then @timeout(arg)
            else @when(arg)

        # Build a request
        build: ->
            # Extract information provided through all chunks
            @_mutate()
            req = new Request
            if @properties.timeout? and @properties.timeout >= 0 then req.timeout @properties.timeout
            if @properties.url then req.url @properties.url

            req.condition(condition) for condition in @properties.conditions
            for callback in @properties.errorHandlers
                req.on(events.TIMEOUT, callback)
                req.on(events.REQUEST_FAILURE, callback)
            #req.on(events.READY, callback) for callback in @properties.actions
            req.action(action) for action in @properties.actions

            req

        # Build and execute a request
        execute: (url) ->
            @from url
            req = @build()
            req.execute()
            req

        _terminated: ->
            # After the first chunk has been applied, expand to allow joining
            # chunks with `and()`
            #
            # Not so sure I like this...
            if typeof @and is 'undefined'
                @and = -> @


    # Events that may be emitted by a Request
    events =
        HALT: 'halted'
        PHANTOM_CREATE: 'phantom-created'
        PAGE_CREATE: 'page-created'
        PAGE_OPEN: 'page-opened'
        TIMEOUT: 'timeout'
        REQUEST_FAILURE: 'failed'
        READY: 'ready'
        FINISH: 'finished'
        CHECKING: 'checking'
    
    
    # A request
    class Request
        # Private method to clean up open Phantom instances and notify listeners
        end = ->
            @emit events.FINISH
            clearInterval @_interval
            @_phantom.exit()

        constructor: ->
            @_url = ''
            @_conditions = []
            @_actions = []
            @_interval = null
            @_phantom = null
            @_page = null
            @_timeout = 3000

        # Add a callback that must return true before emitting ready
        condition: (callback) ->
            if typeof callback isnt 'function' and typeof callback isnt 'object' then throw Error "Invalid condition"
            @_conditions.push callback
            this

        action: (callback) ->
            if typeof callback isnt 'function' then throw Error "Invalid action"
            @_actions.push callback
            this

        # Set or get the timeout value
        timeout: (value) ->
            if typeof value == 'number' && value >= 0
                @_timeout = value
                this
            else
                @_timeout

        # Set or get the URL
        url: (url) ->
            if typeof url == 'string'
                @_url = url
                this
            else
                @_url

        # Interrupt execution and end ASAP
        halt: ->
            @emit events.HALT
            end.call this

        # Execute the request
        execute: (url) ->
            @url url   # Set the URL if it was provided

            phantom.create (ph) =>
                @_phantom = ph
                @emit events.PHANTOM_CREATE
                
                ph.createPage (page) =>
                    @_page = page
                    page.set('onConsoleMessage', (msg) -> console.log 'Phantom Message:', msg)
                    @emit events.PAGE_CREATE

                    page.open @_url, (status) =>
                        if (status != 'success')        # Request failed
                            @emit events.REQUEST_FAILURE
                            end.call this

                        else if @_conditions.length     # Request succeeded, but we have to verify the DOM
                            start = now()

                            # This function is called over and over until all conditions 
                            # have been satisfied or we run out of time.
                            tick = =>
                                @emit events.CHECKING

                                # Timeout
                                if @_timeout > 0 && now() - start > @_timeout
                                    @emit events.TIMEOUT, page
                                    end.call this

                                # Check all conditions
                                else
                                    isReady = true
                                    tests = @_conditions[..]

                                    check = (condition) =>
                                        if typeof condition is 'function'
                                            test = condition
                                            args = null

                                        else if typeof condition is 'object'
                                            [args, test] = condition

                                        handler = (result) =>
                                            isReady = isReady & result
                                            if isReady
                                                if tests.length
                                                    check tests.pop()
                                                else
                                                    action(page) for action in @_actions
                                                    @emit events.READY, page
                                                    end.call this
                                        
                                        page.evaluate test, handler, args

                                    check tests.pop()

                            @_interval = setInterval tick, 250

                        else                            # Request succeeded and no verifications necessary - proceed!
                            @emit events.READY, page
                            action(page) for action in @_actions
                            end.call this

    # Ensure that Request can emit events
    Request.prototype.__proto__ = Emitter.prototype

    # Export bound classes
    exports =
        "Request": Request
        "Builder": Builder
        "create": -> new Builder
        

module.exports = binder()
module.exports.inject = binder
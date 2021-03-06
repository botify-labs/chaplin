'use strict'

_ = require 'underscore'
Backbone = require 'backbone'
mediator = require 'chaplin/mediator'
utils = require 'chaplin/lib/utils'
EventBroker = require 'chaplin/lib/event_broker'

module.exports = class Dispatcher
  # Borrow the static extend method from Backbone.
  @extend = Backbone.Model.extend

  # Mixin an EventBroker.
  _.extend @prototype, EventBroker

  # The previous route information.
  # This object contains the controller name, action, path, and name (if any).
  previousRoute: null

  # The current controller, route information, and parameters.
  # The current route object contains the same information as previous.
  currentController: null
  currentRoute: null
  currentParams: null
  currentQuery: null

  constructor: ->
    @initialize arguments...

  initialize: (options = {}) ->
    # Merge the options.
    @settings = _.defaults options,
      controllerPath: 'controllers/'
      controllerSuffix: '_controller'

    # Listen to global events.
    @subscribeEvent 'router:match', @dispatch
    mediator.setHandler 'router:getCurrentRoute', @getCurrentRoute, this

  # Controller management.
  # Starting and disposing controllers.
  # ----------------------------------

  # The standard flow is:
  #
  #   1. Test if it’s a new controller/action with new params
  #   1. Hide the previous view
  #   2. Dispose the previous controller
  #   3. Instantiate the new controller, call the controller action
  #   4. Show the new view
  #
  dispatch: (route, params, options) ->
    # Clone params and options so the original objects remain untouched.
    params = if params then _.extend {}, params else {}
    options = if options then _.extend {}, options else {}

    # null or undefined query parameters are equivalent to an empty hash
    options.query = {} if not options.query?

    # Whether to force the controller startup even
    # if current and new controllers and params match
    # Default to false unless explicitly set to true.
    options.forceStartup = false unless options.forceStartup is true

    # Stop if the desired controller/action is already active
    # with the same params.
    return if not options.forceStartup and
      @currentRoute?.controller is route.controller and
      @currentRoute?.action is route.action and
      _.isEqual(@currentParams, params) and
      _.isEqual(@currentQuery, options.query)

    # Fetch the new controller, then go on.
    @loadController route.controller, (Controller) =>
      @controllerLoaded route, params, options, Controller

  # Load the constructor for a given controller name.
  # The default implementation uses require() from a AMD module loader
  # like RequireJS to fetch the constructor.
  loadController: (name, handler) ->
    fileName = name + @settings.controllerSuffix
    moduleName = @settings.controllerPath + fileName
    if define?.amd
      require [moduleName], handler
    else
      setTimeout =>
        handler require moduleName
      , 0

  # Handler for the controller lazy-loading.
  controllerLoaded: (route, params, options, Controller) ->
    if @nextPreviousRoute = @currentRoute
      previous = _.extend {}, @nextPreviousRoute
      previous.params = @currentParams if @currentParams?
      delete previous.previous if previous.previous
      prev = {previous}
    @nextCurrentRoute = _.extend {}, route, prev

    controller = new Controller params, @nextCurrentRoute, options
    @executeBeforeAction controller, @nextCurrentRoute, params, options

  # Executes controller action.
  executeAction: (controller, route, params, options) ->
    # Dispose the previous controller.
    if @currentController
      # Notify the rest of the world beforehand.
      @publishEvent 'beforeControllerDispose', @currentController

      # Passing new parameters that the action method will receive.
      @currentController.dispose params, route, options

    # Save the new controller and its parameters.
    @currentController = controller
    @currentParams = _.clone params
    @currentQuery = _.clone options.query

    # Call the controller action with params and options.
    controller[route.action] params, route, options

    # Stop if the action triggered a redirect.
    return if controller.redirected

    # We're done! Spread the word!
    @publishEvent 'dispatcher:dispatch', @currentController,
      params, route, options

  # Executes before action filterer.
  executeBeforeAction: (controller, route, params, options) ->
    before = controller.beforeAction

    executeAction = =>
      if controller.redirected or @currentRoute and route is @currentRoute
        @nextPreviousRoute = @nextCurrentRoute = null
        controller.dispose()
        return
      @previousRoute = @nextPreviousRoute
      @currentRoute = @nextCurrentRoute
      @nextPreviousRoute = @nextCurrentRoute = null
      @executeAction controller, route, params, options

    unless before
      executeAction()
      return

    # Throw deprecation warning.
    if typeof before isnt 'function'
      throw new TypeError 'Controller#beforeAction: function expected. ' +
        'Old object-like form is not supported.'

    # Execute action in controller context.
    promise = controller.beforeAction params, route, options
    if promise and promise.then
      promise.then executeAction
    else
      executeAction()

  getCurrentRoute: ->
    return {
      route: @currentRoute,
      params: @currentParams,
      query: @currentQuery
    }

  # Disposal
  # --------

  disposed: false

  dispose: ->
    return if @disposed

    @unsubscribeAllEvents()

    @disposed = true

    # You’re frozen when your heart’s not open.
    Object.freeze? this

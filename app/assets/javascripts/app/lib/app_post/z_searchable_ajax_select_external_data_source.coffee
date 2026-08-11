class App.ExternalDataSourceAjaxSelect extends App.SearchableAjaxSelect
  constructor: ->
    super

    # Create cache, but allow for it to be overridden for test purposes.
    @searchResultCache = App.ExternalDataSourceAjaxSelect.TEST_SEARCH_RESULT_CACHE || {}

  render: ->
    @attribute.valueType = 'json'

    if @attribute.name
      @attribute.nameRaw = @attribute.name
      @attribute.name = "{#{@attribute.valueType}}#{@attribute.name}"

    if not _.isEmpty(@attribute.value)

      if @attribute.multiple
        @attribute.existingTokens = ''

        @attribute.options = _.map(@attribute.value, (item) ->
          value: item.value
          name: item.label
          selected: true
        )

        for option in @attribute.options
          @attribute.existingTokens += App.view('generic/token')(
            @prepareTokenContent({ name: option.name, value: option.value })
          )

      else
        @attribute.options = [_.extend({}, { value: @attribute.value.value, name: @attribute.value.label, selected: true })]

    else
      @attribute.value = {}
      @attribute.value = [] if @attribute.multiple

    @attribute.valueRaw = JSON.stringify(@attribute.value)

    @renderElement()
    @toggleClear()

  renderOptions: (options) ->
    # We need to transform the value that we don't lose the needed type information.
    options.forEach (option) ->
      option.value = JSON.stringify([option.value])

    super(options)

  updateAttributeValueName: =>
    if @shadowInput.length and _.isEmpty(@getShadowValue())
      @attribute.valueName = ''

      return

    firstSelected = @findFirstSelection(@attribute.options)

    if firstSelected
      @attribute.valueName = firstSelected.name
    else if @attribute.unknown && @attribute.value
      @attribute.valueName = @attribute.value.label
    else if @hasSubmenu @attribute.options
      @attribute.valueName = @getName(@attribute.value, @attribute.options)

  # Extract the human-readable name from an external-source field's live form
  # value. ControllerForm.params strips the '{json}' prefix and JSON-parses the
  # value, so it arrives as an OBJECT ({value,label}) under the PLAIN key
  # ('li_business_unit'). Tolerate object, JSON string, or plain string.
  liveName: (raw) ->
    return '' unless raw
    if typeof raw is 'object'
      return (raw.value ? raw.label) or ''
    if typeof raw is 'string' and raw.charAt(0) is '{'
      try
        obj = JSON.parse(raw)
        return (obj?.value ? obj?.label) or ''
      catch
        return ''
    raw

  cacheKey: =>
    objectName    = @options.attribute.objectName
    attributeName = @options.attribute.attributeName or @options.attribute.nameRaw
    query         = @input.val()

    # For the cascading product field, include the LIVE Business Unit in the
    # cache key so changing the BU refetches instead of serving the previous
    # BU's cached options. Read from the LIVE form (ControllerForm.params), never
    # the stale @delegate.params snapshot, or the cache key lags the real BU.
    bu = ''
    if attributeName is 'li_product' and @delegate and @delegate.form
      bu = @liveName(App.ControllerForm.params(@delegate.form)?.li_business_unit)

    "#{objectName}+#{attributeName}+#{query}+#{bu}"

  ajaxAttributes: =>
    objectName     = @options.attribute.objectName
    attributeName  = @options.attribute.attributeName or @options.attribute.nameRaw
    query          = @input.val()
    search_context = {}

    if @delegate
      params = if @delegate.params?.id then @delegate.params else App.ControllerForm.params(@delegate.form)

      if params.id
        search_context["#{@delegate.model.className.toLowerCase()}_id"] = params.id

      if params.customer_id
        search_context.customer_id = params.customer_id

      # Forward the LIVE (possibly unsaved) Business Unit so a cascading
      # search_url (li_product filtered by #{ticket.li_business_unit}) reacts to
      # the BU the agent just picked WITHOUT needing a save.
      # NOTE 1: the field renames @attribute.name to '{json}li_product' at render,
      #   so match on the un-prefixed nameRaw (NOT .name), or this never fires.
      # NOTE 2: on an existing ticket @delegate.params is a STALE snapshot (it has
      #   the previously-saved BU), so read the BU from the LIVE form via
      #   ControllerForm.params, never from @delegate.params.
      if (@options.attribute.nameRaw ? @options.attribute.name) is 'li_product' and @delegate.form
        liveParams = App.ControllerForm.params(@delegate.form)
        buRaw = liveParams?.li_business_unit
        if buVal = @liveName(buRaw)
          search_context.li_business_unit_live = buVal

    {
      id:   @options.attribute.id
      type: 'GET'
      url:  "#{App.Config.get('api_path')}/external_data_source/#{objectName}/#{attributeName}"
      data:
        query: query,
        limit: @options.attribute.limit,
        search_context: search_context
      processData: true
      success:     (data, status, xhr) =>
        # cache search result
        @searchResultCache[@cacheKey()] = data
        @renderResponse(data, query)
      error: =>
        @hideLoader()
    }

  renderResponseItem: (elem) ->
    {
      name:  elem.label
      value: elem.value
    }

  getShadowValue: =>
    try
      JSON.parse(@shadowInput.val())
    catch
      App.Log.debug 'App.ExternalDataSourceAjaxSelect', 'getShadowValue', @shadowInput.val()
      return [] if @attribute.multiple
      {}

  # Cascade UX: the BU field overrides selectValue (the click-commit point) to
  # clear a stale sibling Product on change. clearSiblingProduct does the work.
  setShadowValue: (newValue) =>
    newValue.value = newValue.value[0] if _.isArray(newValue?.value)

    @shadowInput.val(JSON.stringify(newValue))
      .trigger('change')

  clearSiblingProduct: =>
    form = @el.closest('form')
    return unless form and form.length
    productShadow = form.find('input[name="{json}li_product"]')
    return unless productShadow.length

    try
      current = JSON.parse(productShadow.val() or '{}')
    catch
      current = {}
    return if _.isEmpty(current)

    productShadow.val('{}').trigger('change')
    container = productShadow.closest('.searchableSelect')
    if container.length
      container.find('input.searchableSelect-main').val('').removeAttr('title')
      container.find('.js-clear').addClass('hide')
    App.Log.debug('ExternalDataSource', 'cleared li_product because li_business_unit changed')

  selectValue: (key, value, displayName) =>
    # BU field only: capture the PREVIOUS BU so we can detect a real change and
    # clear the now-stale sibling Product (cascade mismatch guard).
    if @attribute.nameRaw is 'li_business_unit'
      prev = @getShadowValue()
      prevName = prev and (prev.value or prev.label)

    displayName = value

    super

    if key is '' and value is ''
      @setShadowValue({})
      return

    @setShadowValue(value: key, label: value)
    @toggleClear()

    # After a BU change commits, clear the sibling Product if the BU actually changed.
    if @attribute.nameRaw is 'li_business_unit'
      @clearSiblingProduct() if prevName and value and prevName isnt value

  onKeyUp: =>
    return if @input.val().trim() isnt '' || @attribute.multiple
    @setShadowValue({})

  addValueToShadowInput: (currentText, dataId) =>
    @input.val('')
      .removeAttr('title')

    realDataId = if _.isArray(dataId) then dataId[0] else dataId

    value = []
    if not _.isEmpty(@getShadowValue())
      value = @getShadowValue()
      return if _.find(value, (item) -> "#{item.value}" is "#{realDataId}") # cast dataId to string before check
    @currentData = { label: currentText, value: realDataId }
    value.push(@currentData)

    @setShadowValue(value)
    @onShadowChange()

  onShadowChange: ->
    value = @getShadowValue()

    if @attribute.multiple
      value = _.map(value, (item) -> item.value)
    else
      value = value.value

    if @attribute.multiple and @currentData

      # create token
      @createToken(@currentData)
      @currentData = null

    if Array.isArray(@attribute.options)
      for option in @attribute.options
        if @attribute.multiple
          option.selected = _.includes(value or [], option.value.toString())
        else
          option.selected = option.value.toString() is value?.toString()

      if option.children
        @updateAttributeOptionSelected(option.children, value)

  createToken: ({label, value}) =>
    @input.before App.view('generic/token')(
      @prepareTokenContent({ name: label, value: value })
    )

  onEnter: (event) ->
    if @currentItem
      if @currentItem.hasClass('js-back')
        return @navigateOut(event)

    @clearAutocomplete()

    if not @isOpen
      if _.isEmpty(@getShadowValue())
        event.preventDefault()
        @toggle()
      else
        @trigger 'enter'
        @el.trigger 'enter'
      return

    event.preventDefault()

    if @currentItem || !@attribute.unknown
      return if @currentItem.hasClass('has-inactive')

      valueName = @currentItem.children('span.searchableSelect-option-text').text().trim()
      value     = @currentItem.attr('data-value')
      if @attribute.multiple
        @addValueToShadowInput(valueName, value)
      else
        @input.val(valueName)
          .title(valueName)
        @setShadowValue(value: value, label: valueName)

      @currentItem.removeClass('is-active')
      @currentItem.removeClass('is-highlighted') if @currentItem.hasClass('js-enter')
      @currentItem = null

    @input.trigger('change')

    if not @attribute.multiple
      @toggle()
      @input.trigger('blur')

  removeToken: (which) =>
    switch which
      when 'last'
        token = @$('.token').last()
        return if not token.length
      else
        token = which

    id = token.data('value')
    @setShadowValue _.filter(@getShadowValue(), (item) -> "#{item.value}" isnt "#{id}")
    token.remove()

  onInput: (event, doToggle = true) =>
    super

    if @attribute.unknown && !@attribute.multiple
      @setShadowValue(value: @query, label: @query)

  toggleClear: =>
    if not _.isEmpty(@getShadowValue()) and not @isOpen
      @clear.removeClass('hide')
    else
      @clear.addClass('hide')

  clearValue: =>
    event.stopPropagation()

    @selectValue('', '', '')
    @input.trigger('change')
    @markSelected('')
    @toggleClear()

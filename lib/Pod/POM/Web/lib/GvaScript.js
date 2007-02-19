
//----------base.js
/*-------------------------------------------------------------------------*
 * GvaScript - Javascript framework born in Geneva.
 *
 *  Author: Laurent Dami <laurent dot dami at justice dot geneve dot ch>
 *
 *  LICENSE
 *  This library is free software, you can redistribute it and/or modify
 *  it under the same terms as Perl's artistic license.
 *
 *--------------------------------------------------------------------------*/

var GvaScript = {
  Version: '0.0.1'
}


//----------protoExtensions.js
//-----------------------------------------------------
// Some extensions to the prototype javascript framework
//-----------------------------------------------------
if (!window.Prototype)
  throw  new Error("Prototype library is not loaded");

Object.extend(Element, {

  classRegExp : function(wanted_classes) {
    if (typeof wanted_classes != "string" &&
        wanted_classes instanceof Array)
       wanted_classes = wanted_classes.join("|");
    return new RegExp("\\b(" + wanted_classes + ")\\b");
  },

  hasAnyClass: function (elem, wanted_classes) {
    return Element.classRegExp(wanted_classes).test(elem.className);
  },

  getElementsByClassNames: function(parent, wanted_classes) {
    var regexp = Element.classRegExp(wanted_classes);
    var children = ($(parent) || document.body).getElementsByTagName('*');
    var result = [];
    for (var i = 0; i < children.length; i++) {
      var child = children[i];
      if (regexp.test(child.className)) result.push(child);
    }
    return result;
  },

  // start at elem, walk nav_property until find any of wanted_classes
  navigateDom: function (elem, navigation_property, 
                         wanted_classes, stop_condition) {
    while (elem){
       if (stop_condition && stop_condition(elem)) break;
       if (elem.nodeType == 1 &&
           Element.hasAnyClass(elem, wanted_classes))
         return elem;
       // else walk to next element
       elem = elem[navigation_property];
     }
     return null;
  },


  autoScroll: function(elem, percentage) {
     percentage = percentage || 20; // default                  
     var parent = elem.offsetParent;
     var offset = elem.offsetTop;

     // offset calculations are buggy in Gecko, so we need a hack here
     if (/Gecko/.test(navigator.userAgent)) { 
       parent = elem.parentNode;
       while (parent) {
         var overflowY;
         try      {overflowY = Element.getStyle(parent, "overflowY")}
         catch(e) {overflowY = "visible";}
         if (overflowY != "visible") break; // found candidate for offsetParent
         parent = parent.parentNode;
       }
       parent  = parent || document.body;
       offset -= parent.offsetTop
     }

     var min = offset - (parent.clientHeight * (100-percentage)/100);
     var max = offset - (parent.clientHeight * percentage/100);
     if      (parent.scrollTop < min) parent.scrollTop = min;
     else if (parent.scrollTop > max) parent.scrollTop = max;
  },

  equivalentHTML: function(elem) {
     var tag = elem.tagName;
     if (!tag)
         return elem;
     if (elem.outerHTML) {
         return elem.outerHTML;
     } else {
         var attrs = elem.attributes;
         var str = "<" + tag;
         for (var i = 0; i < attrs.length; i++)
             str += " " + attrs[i].name + "=\"" + attrs[i].value + "\"";

         return str + ">" + elem.innerHTML + "</" + elem.tagName + ">";
     }
  }

});

Class.checkOptions = function(defaultOptions, ctorOptions) {
  ctorOptions = ctorOptions || {}; // options passed to the class constructor
  for (var property in ctorOptions) {
    if (defaultOptions[property] === undefined)
      throw new Error("unexpected option: " + property);
  }
  return Object.extend(Object.clone(defaultOptions), ctorOptions);
};
  

Object.extend(Event, {

  detailedStop: function(event, toStop) {
    if (toStop.preventDefault) { 
      if (event.preventDefault) event.preventDefault(); 
      else                      event.returnValue = false;
    }
    if (toStop.stopPropagation) { 
      if (event.stopPropagation) event.stopPropagation(); 
      else                       event.cancelBubble = true;
    }
  },

  stopAll:  {stopPropagation: true, preventDefault: true},
  stopNone: {stopPropagation: false, preventDefault: false}

});


function ASSERT (cond, msg) {
  if (!cond) 
    throw new Error("Violated assertion: " + msg);
}


//----------event.js
// fireEvent : should be COPIED into controller objects, so that 
// 'this' is properly bound to the controller

GvaScript.fireEvent = function(/* type, elem1, elem2, ... */) {

  var event;

  switch (typeof arguments[0]) {
  case "string" : 
    event = {type: arguments[0]}; 
    break;
  case "object" :
    event = arguments[0];
    break;
  default:
    throw new Error("invalid first argument to fireEvent()");
  }
  
  var propName = "on" + event.type;
  var handler;
  var target   = arguments[1]; // first element where the event is triggered
  var currentTarget;           // where the handler is found


  // try to find the handler, first in the HTML elements, then in "this"
  for (var i = 1, len = arguments.length; i < len; i++) {
    var elem = arguments[i];
    if (handler = elem.getAttribute(propName)) {
      currentTarget = elem;
      break;
    }
  }
  if (currentTarget === undefined)
    if (handler = this[propName])
      currentTarget = this;

  if (handler) {
    // build context 
    var controller = this;
    event.target = event.srcElement = target;
    event.currentTarget = currentTarget;
    event.controller    = controller;

    if (typeof(handler) == "string") {
      // string will be eval-ed in a closure context where 'this', 'event',
      // 'target' and 'controller' are defined.
      var eval_handler = function(){return eval( "(" + handler + ")" ) };
      handler = eval_handler.call(currentTarget); // target bound to 'this'
    }

    if (handler instanceof Function) {
      // now call the eval-ed or pre-bound handler
      return handler(event);
    }
    else 
      return handler; // whatever was returned by the string evaluation
  }
  else
    return null; // no handler found
};


//----------keyMap.js
/* Keymap handler, v0.1, Sept 2006, by laurent.dami AT justice.ge.ch.
   See companion file "Keymap.pod" for documentation and license.
*/

// TODO : add a notion of "AntiRegex"

//constructor
GvaScript.KeyMap = function (rules) {
    if (!(rules instanceof Object)) throw "KeyMap: invalid argument";
    this.rules = [rules];
    return this;
};
  

GvaScript.KeyMap.prototype = {
    
  eventHandler: function (options) {

    var keymap = this;

    var defaultOptions = Event.stopAll;
    options = Class.checkOptions(defaultOptions, options || {});

    return function (event) {
      event = event || window.event;

      // translate key code into key name
      event.keyName = keymap._builtinName[event.keyCode] 
	           || String.fromCharCode(event.keyCode);

      // add Control|Shift|Alt modifiers
      event.keyModifiers = "";
      if (event.ctrlKey  && !options.ignoreCtrl)  event.keyModifiers += "C_";
      if (event.shiftKey && !options.ignoreShift) event.keyModifiers += "S_";
      if (event.altKey   && !options.ignoreAlt)   event.keyModifiers += "A_";

      // but cancel all modifiers if main key is Control|Shift|Alt
      if (event.keyName.search(/^(CTRL|SHIFT|ALT)$/) == 0) 
	event.keyModifiers = "";

      // try to get the corresponding handler, and call it if found
      var handler = keymap._findInStack(event, keymap.rules);
      if (handler) {
        var toStop = handler.call(keymap, event);
        Event.detailedStop(event, toStop || options);
      }
    };
  },

  observe: function(eventType, elem, options) {
    eventType = eventType || 'keydown';
    elem      = elem      || document;

    // "Shift" modifier usually does not make sense for keypress events
    if (eventType == 'keypress' && !options) 
      options = {ignoreShift: true};

    Event.observe(elem, eventType, this.eventHandler(options));
  },


  _findInStack: function(event, stack) {

    for (var i = stack.length - 1; i >= 0; i--) {
      var rules = stack[i];

      // trick to differentiate between C_9 (digit) and C_09 (TAB)
      var keyCode = event.keyCode>9 ? event.keyCode : ("0"+event.keyCode);

      var handler = rules[event.keyModifiers + event.keyName]
                 || rules[event.keyModifiers + keyCode];
      if (handler) 
	return handler;

      if (!rules.REGEX) 
	continue;

      for (var j = 0; j < rules.REGEX.length; j++) {
	var rule = rules.REGEX[j];
        var modifiers = rule[0];
        var regex     = rule[1];
        var handler   = rule[2];

        // build regex if it was passed as a string
	if (typeof(regex) == "string") 
            regex = new RegExp("^(" + regex + ")$");

        var same_modifiers = modifiers == null 
                          || modifiers == event.keyModifiers;
	if (same_modifiers && regex.test(event.keyName))
            return handler;
      }
    }
    return null;
  },

  _builtinName: {
      8: "BACKSPACE",
      9: "TAB",
     10: "LINEFEED",
     13: "RETURN",
     16: "SHIFT",
     17: "CTRL",
     18: "ALT",
     19: "PAUSE",
     20: "CAPS_LOCK",
     27: "ESCAPE",
     32: "SPACE",
     33: "PAGE_UP",
     34: "PAGE_DOWN",
     35: "END",
     36: "HOME",
     37: "LEFT",
     38: "UP",
     39: "RIGHT",
     40: "DOWN",
     44: "PRINT_SCREEN", // MSIE6.0: will only fire on keyup!
     45: "INSERT",
     46: "DELETE",
     91: "WINDOWS",
     96: "KP_0",
     97: "KP_1",
     98: "KP_2",
     99: "KP_3",
    100: "KP_4",
    101: "KP_5",
    102: "KP_6",
    103: "KP_7",
    104: "KP_8",
    105: "KP_9",
    106: "KP_STAR",
    107: "KP_PLUS",
    109: "KP_MINUS",
    110: "KP_DOT",
    111: "KP_SLASH",
    112: "F1",
    113: "F2",
    114: "F3",
    115: "F4",
    116: "F5",
    117: "F6",
    118: "F7",
    119: "F8",
    120: "F9",
    121: "F10",
    122: "F11",
    123: "F12",
    144: "NUM_LOCK",
    145: "SCROLL_LOCK"
  }
};

GvaScript.KeyMap.MapAllKeys = function(handler) {
    return {REGEX:[[null, /.*/, handler]]}
};


GvaScript.KeyMap.Prefix = function(rules) {

    // create a specific handler for the next character ...
    var one_time_handler = function (event) {
        this.rules.pop(); // cancel prefix
        var handler = this._findInStack(event, [rules]);
        if (handler) handler.call(this, event);
    }

    // ... and push that handler on top of the current rules
    return function(event) {
        this.rules.push(KeyMap.MapAllKeys(one_time_handler));
    }
};


//----------treeNavigator.js
//-----------------------------------------------------
// Constructor
//-----------------------------------------------------

GvaScript.TreeNavigator = function(elem, options) {

  // fix bug of background images on dynamic divs in MSIE 6.0, see URLs
  // http://www.bazon.net/mishoo/articles.epl?art_id=958
  // http://misterpixel.blogspot.com/2006/09/forensic-analysis-of-ie6.html
  try { document.execCommand("BackgroundImageCache",false,true); }
  catch(e) {}; 


  elem = $(elem); // in case we got an id instead of an element
  options = options || {};

  // default options
  var defaultOptions = {
    tabIndex            : -1,
    flashDuration       : 200,     // milliseconds
    flashColor          : "red",
    selectDelay         : 200,     // milliseconds
    selectOnButtonClick : false,
    createButtons       : true,
    autoScrollPercentage: 20,
    classes             : {},
    keymap              : null,
    selectFirstNode     : true
  };

  this.options = Class.checkOptions(defaultOptions, options);

  // values can be single class names or arrays of class names
  var defaultClasses = {
    node     : "TN_node",
    leaf     : "TN_leaf",
    label    : "TN_label",
    closed   : "TN_closed",
    content  : "TN_content",
    selected : "TN_selected",
    mouse    : "TN_mouse",
    button   : "TN_button",
    showall  : "TN_showall"
  };
  this.classes = Class.checkOptions(defaultClasses, this.options.classes);
  this.classes.nodeOrLeaf = [this.classes.node, this.classes.leaf].flatten();

  // connect to the root element
  this.rootElement = elem;
  this.initSubTree(elem);

  // initializing the keymap
  var keyHandlers = {
    DOWN:       this._downHandler   .bindAsEventListener(this),
    UP:         this._upHandler     .bindAsEventListener(this),
    LEFT:       this._leftHandler   .bindAsEventListener(this),
    RIGHT:      this._rightHandler  .bindAsEventListener(this),
    KP_PLUS:    this._kpPlusHandler .bindAsEventListener(this),
    KP_MINUS:   this._kpMinusHandler.bindAsEventListener(this),
    KP_STAR:    this._kpStarHandler .bindAsEventListener(this),
    KP_SLASH:   this._kpSlashHandler.bindAsEventListener(this),
    C_R:        this._ctrl_R_handler.bindAsEventListener(this),
    RETURN:     this._ReturnHandler .bindAsEventListener(this),
    C_KP_STAR:  this._showAll       .bindAsEventListener(this, true),
    C_KP_SLASH: this._showAll       .bindAsEventListener(this, false),
    HOME:       this._homeHandler   .bindAsEventListener(this),
    END:        this._endHandler    .bindAsEventListener(this),

    // to think : do these handlers really belong to Tree.Navigator?
    PAGE_DOWN:function(event){window.scrollBy(0, document.body.clientHeight/2);
                              Event.stop(event)},
    PAGE_UP:  function(event){window.scrollBy(0, - document.body.clientHeight/2);
                              Event.stop(event)}
  };
  if (this.options.tabIndex >= 0)
    keyHandlers["TAB"] = this._tabHandler.bindAsEventListener(this);

  // handlers for ctrl_1, ctrl_2, etc. to open the tree at that level
  var numHandler = this._chooseLevel.bindAsEventListener(this);
  $R(1, 9).each(function(num){keyHandlers["C_" + num] = numHandler});

  if (options.keymap) {
    this.keymap = options.keymap;
    this.keymap.rules.push(keyHandlers);
  }
  else {
    this.keymap = new GvaScript.KeyMap(keyHandlers);

    // if the tree labels have no tabIndex, only the document receives 
    // keyboard events
    var target = this.options.tabIndex < 0 ? document : elem;
    this.keymap.observe("keydown", target, {preventDefault:false,
                                            stopPropagation:false});
  }

  // selecting the first node
  if (this.options.selectFirstNode)
    this.select(this.firstSubNode());
}


GvaScript.TreeNavigator.prototype = {

//-----------------------------------------------------
// Public methods
//-----------------------------------------------------


  initSubTree: function (elem) {
    var labels = Element.getElementsByClassNames(elem, this.classes.label);
    this._addButtonsAndHandlers(labels); 
    this._addTabbingBehaviour(labels);
  },

  isClosed: function (node) {
    return Element.hasAnyClass(node, this.classes.closed); 
  },

  isVisible: function(elem) { // true if elem is not display:none
    return elem.offsetTop > -1;
  },

  isLeaf: function(node) {
    return Element.hasAnyClass(node, this.classes.leaf);
  },

  isRootElement: function(elem) {
    return (elem === this.rootElement);
  },


  close: function (node) {
    if (this.isLeaf(node))
      return;
    Element.addClassName(node, this.classes.closed);             
    this.fireEvent("Close", node, this.rootElement);

    // if "selectedNode" is no longer visible, select argument node as current
    var selectedNode = this.selectedNode;
    var walkNode = selectedNode;
    while (walkNode && walkNode !== node) {
      walkNode = this.parentNode(walkNode);
    }
    if (walkNode && selectedNode !== node) 
      this.select(node);
  },

  open: function (node) {
    if (this.isLeaf(node))
      return;

    Element.removeClassName(node, this.classes.closed);
    this.fireEvent("Open", node, this.rootElement);
    if (!this.content(node))
      this.loadContent(node);
  },


  openEnclosingNodes: function (elem) {
    var node = Element.navigateDom(
      $(elem), 'parentNode', this.classes.node, 
      this.isRootElement.bind(this));
    while (node) {
      if (this.isClosed(node))
        this.open(node);
      node = this.parentNode(node);
    }
  },

  openAtLevel: function(elem, level) {
    var method = this[(level > 1) ? "open" : "close"];
    var node = this.firstSubNode(elem);
    while (node) {
      method.call(this, node); // open or close
      this.openAtLevel(node, level-1);
      node = this.nextSibling(node);
    }
  },

  loadContent: function (node) {
    var url = node.getAttribute('tn:contenturl');
    // TODO : default URL generator at the tree level

    if (url) {
      var content = this.content(node);
      if (!content) {
        content = document.createElement('div');
        content.className = this.classes.content;
        content.innerHTML = "loading " + url;
        node.insertBefore(content, null); // null ==> insert at end of node
      }
      this.fireEvent("BeforeLoadContent", node, this.rootElement);

      var treeNavigator = this; // needed for closure below
      var callback = function() {
        treeNavigator.initSubTree(content);
        treeNavigator.fireEvent("AfterLoadContent", node, this.rootElement);
      };
      new Ajax.Updater(content, url, {onComplete: callback});
      return true;
    }
  },

  select: function (node) {
    var previousNode  = this.selectedNode;

    // re-selecting the current node is a no-op
    if (node == previousNode) return;

    // deselect the previously selected node
    if (previousNode) {
        var label = this.label(previousNode);
        if (label) Element.removeClassName(label, this.classes.selected);
    }

    // register code to call the selection handlers after some delay
    var now = (new Date()).getTime(); 
    this._lastSelectTime = now;
    if (! this._selectionTimeoutId) {
      var callback = this._selectionTimeoutHandler.bind(this, previousNode);
      this._selectionTimeoutId = 
        setTimeout(callback, this.options.selectDelay);
    }

    // select the new node
    this.selectedNode = node;
    if (node) {
      this._assertNodeOrLeaf(node, 'select node');
      var label = this.label(node);
      if (label) {
        Element.addClassName(label, this.classes.selected);

        if (this.isVisible(label)) {
          if (this.options.autoScrollPercentage !== null)
            Element.autoScroll(label, this.options.autoScrollPercentage);
          if (this.options.tabIndex >= 0)          
            label.focus();
        }
      }
      else throw new Error("selected node has no label");
    }
  },


  label: function(node) {
    this._assertNodeOrLeaf(node, 'label: arg type');
    return Element.navigateDom(node.firstChild, 'nextSibling',
                               this.classes.label);
  },

  content: function(node) {
    if (this.isLeaf(node)) return null;
    this._assertNode(node, 'content: arg type');
    return Element.navigateDom(node.lastChild, 'previousSibling',
                               this.classes.content);
  },

  parentNode: function (node) {
    this._assertNodeOrLeaf(node, 'parentNode: arg type');
    return Element.navigateDom(
      node.parentNode, 'parentNode', this.classes.node, 
      this.isRootElement.bind(this));
  },

  nextSibling: function (node) {
    this._assertNodeOrLeaf(node, 'nextSibling: arg type');
    return Element.navigateDom(node.nextSibling, 'nextSibling',
                               this.classes.nodeOrLeaf);
                                 
  },

  previousSibling: function (node) {
    this._assertNodeOrLeaf(node, 'previousSibling: arg type');
    return Element.navigateDom(node.previousSibling, 'previousSibling',
                               this.classes.nodeOrLeaf);
                                 
  },

  firstSubNode: function (node) {
    node = node || this.rootElement;
    var parent = (node == this.rootElement) ? node 
               : this.isLeaf(node)          ? null
               :                              this.content(node);
    return parent ? Element.navigateDom(parent.firstChild, 'nextSibling',
                                        this.classes.nodeOrLeaf)
                  : null;
  },

  lastSubNode: function (node) {
    node = node || this.rootElement;
    var parent = (node == this.rootElement) ? node 
               : this.isLeaf(node)          ? null
               :                              this.content(node);
    return parent ? Element.navigateDom(parent.lastChild, 'previousSibling',
                                        this.classes.nodeOrLeaf)
                  : null;
  },

  lastVisibleSubnode: function(node) {
    node = node || this.rootElement;
    while(!this.isClosed(node)) {
      var lastSubNode = this.lastSubNode(node);
      if (!lastSubNode) break;
      node = lastSubNode;
    }
    return node;
  },

  // find next displayed node (i.e. skipping hidden nodes).
  nextDisplayedNode: function (node) {
    this._assertNodeOrLeaf(node, 'nextDisplayedNode: arg type');

    // case 1: node is opened and has a subtree : then return first subchild
    if (!this.isClosed(node)) {
      var firstSubNode = this.firstSubNode(node);
      if (firstSubNode) return firstSubNode;
    }
	
    // case 2: current node or one of its parents has a sibling 
    while (node) {
      var sibling = this.nextSibling(node);

      if (sibling) {
        if (this.isVisible(sibling)) 
          return sibling;
        else 
          node = sibling;
      }
      else
        node = this.parentNode(node);
    }

    // case 3: no next Node
    return null;
  },

  // find previous displayed node (i.e. skipping hidden nodes).
  previousDisplayedNode: function (node) {
    this._assertNodeOrLeaf(node, 'previousDisplayedNode: arg type');
    var node_init = node;

    while (node) {
      node = this.previousSibling(node);
      if (node && this.isVisible(node))
        return this.lastVisibleSubnode(node);
    }

    // if no previous sibling
    return this.parentNode(node_init);
  },

  // set node background to red for 200 milliseconds
  flash: function (node, milliseconds, color) {

    if (this._isFlashing) return;
    this._isFlashing = true;

    var label         = this.label(node);
    ASSERT(label, "node has no label");
    var previousColor = label.style.backgroundColor;
    var treeNavigator = this;
    var endFlash      = function() {
      treeNavigator._isFlashing = false;
      label.style.backgroundColor = previousColor;
    };
    setTimeout(endFlash, milliseconds || this.options.flashDuration);

    label.style.backgroundColor = color || this.options.flashColor;
  },

  fireEvent: function(eventName, elem) {
    var args = [eventName];
    while (elem) {
      args.push(elem);
      elem = this.parentNode(elem);
    }
    args.push(this.rootElement);
    return GvaScript.fireEvent.apply(this, args);
  },
  
//-----------------------------------------------------
// Private methods
//-----------------------------------------------------

  _assertNode: function(elem, msg) {
    ASSERT(elem && Element.hasAnyClass(elem, this.classes.node), msg);
  },

  _assertNodeOrLeaf: function(elem, msg) {
    ASSERT(elem && Element.hasAnyClass(elem, this.classes.nodeOrLeaf), msg);
  },


  _labelMouseOverHandler: function(event, label) {
      Element.addClassName(label, this.classes.mouse);
      Event.stop(event);
  },

  _labelMouseOutHandler: function(event, label) {
    Element.removeClassName(label, this.classes.mouse);
    Event.stop(event);
  },
  
  _labelClickHandler : function(event, label) {
    var node = label.parentNode;
    this.select(node);
    var to_stop = this.fireEvent("Ping", node, this.rootElement);
    Event.detailedStop(event, to_stop || Event.stopAll);
  },

  _buttonClickHandler : function(event) {
    var node = Event.element(event).parentNode;
    var method = this.isClosed(node) ? this.open : this.close;
    method.call(this, node);
    if (this.options.selectOnButtonClick)
      this.select(node);
    Event.stop(event);
  },

  _addButtonsAndHandlers: function(labels) {
    for (var i = 0; i < labels.length; i++) {
      var label = labels[i];
      Event.observe(
        label,  "mouseover", 
        this._labelMouseOverHandler.bindAsEventListener(this, label));
      Event.observe(
        label,  "mouseout",  
        this._labelMouseOutHandler.bindAsEventListener(this, label));
      Event.observe(
        label,  "click",
        this._labelClickHandler.bindAsEventListener(this, label));
      if (this.options.createButtons) {
        var button = document.createElement("span");
        button.className = this.classes.button;
        label.parentNode.insertBefore(button, label);
        Event.observe(
          button, "click",     
          this._buttonClickHandler.bindAsEventListener(this, label));
      }
    }
  },

  _addTabbingBehaviour: function(labels) {
    if (this.options.tabIndex < 0) return; // no tabbing
    var treeNavigator = this;
    var focus_handler = function(event) {
      var label = Event.element(event);
      var node  = Element.navigateDom(label, 'parentNode',
                                      treeNavigator.classes.nodeOrLeaf);
                                                 
      if (node) treeNavigator.select(node); 
    };
    var blur_handler = function(event) {
      treeNavigator.select(null);
    };
    labels.each(function(label) {
                  label.tabIndex = treeNavigator.options.tabIndex;
                  Event.observe(label, "focus", focus_handler);
                  Event.observe(label, "blur", blur_handler);
                });
  },


//-----------------------------------------------------
// timeout handler for firing Select/Deselect events
//-----------------------------------------------------

  _selectionTimeoutHandler: function(previousNode) {
    var now = (new Date()).getTime();
    var deltaDelay = this.options.selectDelay - (now - this._lastSelectTime);

    // if _lastSelectTime is too recent, re-schedule the same handler for later
    if (deltaDelay > 0) {
      var treeNavigator = this;
      var callback = function () {
        treeNavigator._selectionTimeoutHandler(previousNode);
      };

      this._selectionTimeoutId = 
        setTimeout(callback, deltaDelay + 100); // allow for 100 more milliseconds
    }
    else { // do the real work
      this._selectionTimeoutId = null;
      var newNode = this.selectedNode;
      if (previousNode != newNode) {
        if (previousNode) 
          this.fireEvent("Deselect", previousNode, this.rootElement);
        if (newNode)
          this.fireEvent("Select", newNode, this.rootElement);
      }
    }
  },


//-----------------------------------------------------
// Key handlers
//-----------------------------------------------------

  _downHandler: function (event) {
    var selectedNode = this.selectedNode;
    if (selectedNode) {
      var nextNode = this.nextDisplayedNode(selectedNode);
      if (nextNode)
        this.select(nextNode);
      else
        this.flash(selectedNode); 
      Event.stop(event);
    }
  },

  _upHandler: function (event) {
    var selectedNode = this.selectedNode;
    if (selectedNode) {
      var prevNode = this.previousDisplayedNode(selectedNode);
      if (prevNode)
        this.select(prevNode);
      else
        this.flash(selectedNode); 
      Event.stop(event);
    }
  },

  _leftHandler: function (event) {
    var selectedNode = this.selectedNode;
    if (selectedNode) {
      if (!this.isLeaf(selectedNode) && !this.isClosed(selectedNode)) { 
        this.close(selectedNode);
      } 
      else {
        var parent = this.parentNode(selectedNode); 
        if (parent) 
          this.select(parent); 
        else
          this.flash(selectedNode); 
      }
      Event.stop(event);
    }
  },

  _rightHandler: function (event) {
    var selectedNode = this.selectedNode;
    if (selectedNode) {
      if (this.isLeaf(selectedNode)) return;
      if (this.isClosed(selectedNode))
        this.open(selectedNode);
      else {
        var subNode = this.firstSubNode(selectedNode); 
        if (subNode) 
          this.select(subNode);
        else
          this.flash(selectedNode);
      }
      Event.stop(event);
    }
  },


  _tabHandler: function (event) {
    var selectedNode = this.selectedNode;
    if (selectedNode && this.isClosed(selectedNode)) {
      this.open(selectedNode);
      var label = this.label(selectedNode);
      Event.stop(event);
    }
  },

  _kpPlusHandler: function (event) {
    var selectedNode = this.selectedNode;
    if (selectedNode && this.isClosed(selectedNode)) 
      this.open(selectedNode);
  },

  _kpMinusHandler: function (event) {
    var selectedNode = this.selectedNode;
    if (selectedNode && !this.isClosed(selectedNode)) 
      this.close(selectedNode);
  },

  _kpStarHandler: function (event) {
    var treeNavigator = this;
    var target = this.selectedNode || this.rootElement;
    var nodes = Element.getElementsByClassNames(target, this.classes.node);
    if (target == this.selectedNode) nodes.unshift(target);
    nodes.each(function(node) {treeNavigator.open(node)});
    Event.stop(event);
  },

  _kpSlashHandler: function (event) {
    var treeNavigator = this;
    var target = this.selectedNode || this.rootElement;
    var nodes = Element.getElementsByClassNames(target, this.classes.node);
    if (target == this.selectedNode) nodes.unshift(target);
    nodes.each(function(node) {treeNavigator.close(node)});
    Event.stop(event);
  },

  _ctrl_R_handler: function (event) {
    var selectedNode = this.selectedNode;
    if (selectedNode) {
      if (this.loadContent(selectedNode))
        Event.stop(event);
    }
  },

  _ReturnHandler: function (event) {
    var selectedNode = this.selectedNode;
    if (selectedNode) {
      var toStop = this.fireEvent("Ping", selectedNode, this.rootElement);
      Event.detailedStop(event, toStop || Event.stopAll);
    }
  },

  _homeHandler: function (event) {
    this.select(this.firstSubNode());
    Event.stop(event);
  },

  _endHandler: function (event) {
    this.select(this.lastVisibleSubnode());
    Event.stop(event);
  },

  _chooseLevel: function(event) {
    var level = event.keyCode - "0".charCodeAt(0);
    this.openAtLevel(this.rootElement, level);
  },

  _showAll: function(event, toggle) {
    var method = toggle ? Element.addClassName : Element.removeClassName;
    method(this.rootElement, this.classes.showall);
  }

};

//----------choiceList.js

//----------------------------------------------------------------------
// CONSTRUCTOR
//----------------------------------------------------------------------

GvaScript.ChoiceList = function(choices, options) {
  if (! (choices instanceof Array) )
    throw new Error("invalid choices argument : " + choices);
  this.choices = choices;

  var defaultOptions = {
    labelField       : "label",
    classes          : {},        // see below for default classes
    idForChoices     : "CL_choice",
    keymap           : null,
    grabfocus        : false
  };


  this.options = Class.checkOptions(defaultOptions, options);

  var defaultClasses = {
    choiceItem      : "CL_choiceItem",
    choiceHighlight : "CL_highlight"
  };
  this.classes = Class.checkOptions(defaultClasses, this.options.classes);


  // prepare some stuff to be reused when binding to inputElements
  this.reuse = {
    onmouseover : this._listOverHandler.bindAsEventListener(this),
    onclick     : this._clickHandler.bindAsEventListener(this),
    navigationRules: {
      DOWN:   this._highlightDelta.bindAsEventListener(this, 1),
      UP:     this._highlightDelta.bindAsEventListener(this, -1),
      HOME:   this._highlightDelta.bindAsEventListener(this, -99999),
      END:    this._highlightDelta.bindAsEventListener(this, 99999),
      // TODO: PAGE_UP/DOWN : call server to get next/previous page
      RETURN: this._returnHandler .bindAsEventListener(this),
      ESCAPE: this._escapeHandler .bindAsEventListener(this)
    }
  };
};


GvaScript.ChoiceList.prototype = {

//----------------------------------------------------------------------
// PUBLIC METHODS
//----------------------------------------------------------------------

  fillContainer: function(containerElem) {

    this.container = containerElem;
    this.container.choiceList = this;
    
    Element.update(this.container, this.htmlForChoices());

    // mouse events on choice items will bubble up to the container
    Event.observe(this.container, "mouseover", this.reuse.onmouseover);
    Event.observe(this.container, "click"    , this.reuse.onclick);

    if (this.options.keymap) {
      this.keymap = this.options.keymap;
      this.keymap.rules.push(this.reuse.navigationRules);
    }
    else {
      this.keymap = new GvaScript.KeyMap(this.reuse.navigationRules);
      var target = this.container.tabIndex == undefined 
                     ? document
                     : this.container;
      this.keymap.observe("keydown", target);
    }
    // POTENTIAL PROBLEM HERE : the keymap may stay active
    // even after the choiceList is deleted (may yield memory leaks and 
    // inconsistent behaviour). But we have no "destructor", so how
    // can we unregister the keymap ?


    // highlight the first choice
    this._highlightChoiceNum(0, false);
  },

  updateContainer: function(container, list) {
    this.choices = list;
    Element.update(this.container, this.htmlForChoices());
    this._highlightChoiceNum(0, true);
  },

  htmlForChoices: function(){ // creates the innerHTML 
    var html = "";
    for (var i = 0; i < this.choices.length; i++) {
      var choice = this.choices[i];
      var label  = 
        typeof choice == "string" ? choice : choice[this.options.labelField];

      html += "<div class='" + this.classes.choiceItem
           +  "' id='" + this.container.id + "." + this.options.idForChoices + "." + i
           +  "'>" + label + "</div>";
    }
    return html;
  }, 

  fireEvent: GvaScript.fireEvent, // must be copied here for binding "this" 


//----------------------------------------------------------------------
// PRIVATE METHODS
//----------------------------------------------------------------------


  //----------------------------------------------------------------------
  // conversion index <=> HTMLElement
  //----------------------------------------------------------------------

  _choiceElem: function(index) { // find DOM element from choice index
    return $(this.container.id + "." + this.options.idForChoices + "." + index);
  },

  _choiceIndex: function(elem) {
    return parseInt(elem.id.match(/\.(\d+)$/)[1], 10);
  },


  //----------------------------------------------------------------------
  // highlighting 
  //----------------------------------------------------------------------

  _highlightChoiceNum: function(newIndex, autoScroll) {
    Element.removeClassName(this._choiceElem(this.currentHighlightedIndex), 
                            this.classes.choiceHighlight);
    this.currentHighlightedIndex = newIndex;
    var elem = this._choiceElem(newIndex);
    Element.addClassName(elem, this.classes.choiceHighlight);

    if (autoScroll) 
      Element.autoScroll(elem, 30); // 30%

    this.fireEvent({type: "Highlight", index: newIndex}, elem, this.container);
  },


  _highlightDelta: function(event, delta) {
    var currentIndex = this.currentHighlightedIndex;
    var nextIndex    = currentIndex + delta;
    if (nextIndex < 0) 
      nextIndex = 0;
    if (nextIndex >= this.choices.length) 
      nextIndex = this.choices.length -1;

    var autoScroll = event && event.keyName; // autoScroll only for key events
    this._highlightChoiceNum(nextIndex, autoScroll);
                             
    if (event) Event.stop(event);
  },


  //----------------------------------------------------------------------
  // navigation 
  //----------------------------------------------------------------------

  _findChoiceItem: function(event) { // walk up DOM to find mouse target
    var stop_condition = function(elem){return elem === this.container};
    return Element.navigateDom(Event.element(event), "parentNode",
                               this.classes.choiceItem,
                               stop_condition);
  },

  _listOverHandler: function(event) {
    var elem = this._findChoiceItem(event);
    if (elem) {
      this._highlightChoiceNum(this._choiceIndex(elem), false);
      if (this.options.grabfocus)
        this.container.focus();
      Event.stop(event);
    }
  },

  // no _listOutHandler needed

  _clickHandler: function(event) {
    var elem = this._findChoiceItem(event);
    if (elem) {
      var toStop = this.fireEvent({type : "Ping", 
                                   index: this._choiceIndex(elem)}, 
                                  elem, 
                                  this.container);
      Event.detailedStop(event, toStop || Event.stopAll);
    }
  },

  _returnHandler: function(event) {
    var index = this.currentHighlightedIndex;
    if (index != undefined) {
      var elem = this._choiceElem(index);
      var toStop = this.fireEvent({type : "Ping", 
                                   index: index}, elem, this.container);
      Event.detailedStop(event, toStop || Event.stopAll);
    }
  },

  _escapeHandler: function(event) {
    var toStop = this.fireEvent("Cancel", this.container);
    Event.detailedStop(event, toStop || Event.stopAll);
  }

};


//----------autoCompleter.js
/** 
TODO: 
  - if ignorePrefix, should highlight current value (not the 1st one)
  - ctor option: caseSensitive
  - BUG: if strict && noBlank && Ajax server down, MSIE takes 100% CPU
  - messages : choose language

**/

//----------------------------------------------------------------------
// CONSTRUCTOR
//----------------------------------------------------------------------

GvaScript.AutoCompleter = function(datasource, options) {

  var defaultOptions = {
    minimumChars     : 1,
    labelField       : "label",
    valueField       : "value",
    autoSuggest      : true,      // will dropDown automatically on keypress
    autoSuggestDelay : 200,       // milliseconds
    typeAhead        : true,      // will fill the inputElement on highlight
    classes          : {},        // see below for default classes
    maxHeight        : 200,       // pixels
    minWidth         : 200,       // pixels
    offsetX          : 0,         // pixels
    strict           : false,     // will not force to take value from choices
    blankOK          : true,
    ignorePrefix     : false,     // will always display the full choice list
    colorIllegal     : "red"
  };

  this.options = Class.checkOptions(defaultOptions, options);

  var defaultClasses = {
    dropdown        : "AC_dropdown",
    message         : "AC_message",
    loading         : "AC_loading"
  };
  this.classes = Class.checkOptions(defaultClasses, this.options.classes);

  this.dropdownDiv = null;

  // install self-update function, depending on datasource type
  this.updateChoices = this._updateChoicesFunction(datasource);

  // prepare a keymap for all key presses; will be registered at first
  // focus() event; then a second set of keymap rules is pushed/popped
  // whenever the choice list is visible
  var basicHandler = this._keyPressHandler.bindAsEventListener(this);
  var basicMap     = GvaScript.KeyMap.MapAllKeys(basicHandler);
  this.keymap = new GvaScript.KeyMap(basicMap);

  // prepare some stuff to be reused when binding to inputElements
  this.reuse = {
    onblur : this._blurHandler.bindAsEventListener(this)
  };
}


GvaScript.AutoCompleter.prototype = {

//----------------------------------------------------------------------
// PUBLIC METHODS
//----------------------------------------------------------------------

  // called when the input element gets focus
  autocomplete: function(elem) { 
    elem = $(elem);// in case we got an id instead of an element

    if (!elem) throw new Error("attempt to autocomplete a null element");

    // if we were the last to have focus, just recover it, no more work.
    if (elem === this.inputElement) return;

    this.inputElement   = elem;

    if (!elem._autocompleter) { // register handlers only if new elem
      elem._autocompleter = this;
      this.keymap.observe("keydown", elem, { preventDefault:false,
                                             stopPropagation:false});
      Element.observe(elem, "blur", this.reuse.onblur);
    }

    // initialize time stamps
    this._timeLastCheck = this._timeLastKeyPress = 0;

    // more initialization, but only if we did not just come back from a 
    // click on the dropdownDiv
    if (!this.dropdownDiv) {
      this.lastValue      = null;
      this.fireEvent("Bind", elem);
    }

    this._checkNewValue();
  },

  detach: function(elem) {
    elem._autocompleter = null;
    Element.stopObserving(elem, "blur", this.reuse.onblur);
    Element.stopObserving(elem, "keydown", elem.onkeydown);
  },

  displayMessage : function(message) {
    this._removeDropdownDiv();
    var div = this._mkDropdownDiv();
    div.innerHTML = message;
    Element.addClassName(div, this.classes.message);
  },

  fireEvent: GvaScript.fireEvent, // must be copied here for binding "this" 


//----------------------------------------------------------------------
// PRIVATE METHODS
//----------------------------------------------------------------------

  // an auxiliary function for the constructor
  _updateChoicesFunction : function(datasource) { 
    if (typeof datasource == "string") { // URL
      return function () {
        var autocompleter = this; // needed for closures below
        autocompleter.inputElement.style.backgroundColor = ""; // remove colorIllegal
        if (this._runningAjax)
          this._runningAjax.transport.abort();
        Element.addClassName(autocompleter.inputElement, this.classes.loading);
        this._runningAjax = new Ajax.Request(
          datasource + autocompleter.inputElement.value,
          {asynchronous: true,
           onSuccess: function(xhr) {
              autocompleter._runningAjax = null;
              autocompleter.choices = eval("(" + xhr.responseText + ")");
              autocompleter._displayChoices();
           },
           onFailure: function(xhr) {
              autocompleter._runningAjax = null;
              autocompleter.displayMessage("Ajax request failed");
           },
           onComplete: function(xhr) {
              Element.removeClassName(autocompleter.inputElement, 
                                      autocompleter.classes.loading);
           }
          });
        return true; // asynchronous
      };
    }
    else if (typeof datasource == "function") { // callback
      return function() {
        this.inputElement.style.backgroundColor = ""; // remove colorIllegal
        this.choices = datasource(this.inputElement.value);
        return false; // not asynchronous
      };
    }
    else if (typeof datasource == "object" &&
             datasource instanceof Array) { // in-memory
      return function () {
        this.inputElement.style.backgroundColor = ""; // remove colorIllegal
        if (this.options.ignorePrefix)
          this.choices = datasource;
        else {
          var prefix = this.inputElement.value;
          var isPrefixed = function(choice) {
            var value = 
            (typeof choice == "string") ? choice 
            : choice[this.options.valueField];
            return value.indexOf(prefix) == 0;
          };
          this.choices = datasource.select(isPrefixed.bind(this));
        }
        return false; // not asynchronous
      };
    }
    else 
      throw new Error("unexpected datasource type");
  },


  _blurHandler: function(event) { // does the reverse of "autocomplete()"

    Element.removeClassName(this.inputElement, this.classes.loading);

    // check if this is a "real" blur, or just a clik on dropdownDiv
    if (this.dropdownDiv) {
      var x = Event.pointerX(window.event);
      var y = Event.pointerY(window.event);
      if (Position.within(this.dropdownDiv, x, y)) {
        // not a "real" blur ==> bring focus back to the input element
        this.inputElement.focus(); // will trigger again this.autocomplete()
        return;
      }
      else {
        this._removeDropdownDiv();
      }
    }
    if (this.options.strict) {
      var valueOK = false;
      if (this.choiceList) {
        var index = this.choiceList.currentHighlightedIndex;
        var legal = this._valueFromChoice(index);
        if (legal == null && this.options.blankOK)
          legal = "";
        valueOK = this.inputElement.value == legal;
      }
      if (!valueOK) {
        // this.displayMessage("not a legal value"); 
        // this.inputElement.select(); 
        this.inputElement.style.backgroundColor = this.options.colorIllegal;
      }
    }
        
    this.fireEvent("Leave", this.inputElement);
    this.inputElement = null;
  },


  _keyPressHandler: function(event) { 

    // after a blur, we still get a keypress, so ignore it
    if (!this.inputElement) return; 

    if (event.keyName == "DOWN") { // user wants the list now ==> no timeout
      if (!this.inputElement.value || (this.inputElement.value.length < this.options.minimumChars))
        this.displayMessage("liste de choix à partir de " 
                            + this.options.minimumChars + " caractères");
      else 
        this._displayChoices();
      Event.stop(event);
    }
    else if (! /^(SHIFT|CTRL|ALT|LEFT|RIGHT)$/.test(event.keyName)) {
      // first give back control so that the inputElement updates itself,
      // then come back through a timeout to update the Autocompleter

      // cancel pending timeouts because we create a new one
      if (this._timeoutId) clearTimeout(this._timeoutId);

      this._timeLastKeyPress = (new Date()).getTime(); 
      this._timeoutId = setTimeout(this._checkNewValue.bind(this), 
                                   this.options.autoSuggestDelay);
      // do NOT stop the event here .. inputElement needs to get the event
    }
  },



  _checkNewValue: function() { 

    // ignore this keypress if after a blur (no input element)
    if (!this.inputElement) return; 

    // several calls to this function may be queued by setTimeout,
    // so we perform some checks to avoid doing the work twice
    if (this._timeLastCheck > this._timeLastKeyPress)
      return; // the work was done already
    var now = (new Date()).getTime();
    var deltaTime = now - this._timeLastKeyPress;
    if (deltaTime <  this.options.checkvalueDelay) 
      return; // too young, let olders do the work

    // OK, we really have to check the value now
    this._timeLastCheck = now;
    var value = this.inputElement.value;
    if (value != this.lastValue) {
      this.lastValue = value;
      this.choices = null; // value changed, so invalidate previous choices
      this.choiceList = null;

      if (value.length >= this.options.minimumChars
          && this.options.autoSuggest)
        this._displayChoices();
      else
        this._removeDropdownDiv();
    }
  },


  _typeAhead : function () {
    var curLen     = this.lastValue.length;
    var index      = this.choiceList.currentHighlightedIndex; 
    var suggestion = this._valueFromChoice(index);
    var newLen     = suggestion.length;
    this.inputElement.value = suggestion;

    if (this.inputElement.createTextRange){ // MSIE
      var range = this.inputElement.createTextRange();
      range.moveStart("character", curLen); // no need to moveEnd
      range.select(); // will call focus();
    }
    else if (this.inputElement.setSelectionRange){ // Mozilla
      this.inputElement.setSelectionRange(curLen, newLen);
    }
  },



//----------------------------------------------------------------------
// methods for the dropdown list of choices
//----------------------------------------------------------------------

  _mkDropdownDiv : function() {
    this._removeDropdownDiv();

    // create div
    var div    = document.createElement('div');
    div.className = this.classes.dropdown;

    // positioning
    var coords = Position.cumulativeOffset(this.inputElement);
    var dim    = Element.getDimensions(this.inputElement);
    div.style.left      = (coords[0]+this.options.offsetX) + "px";
    div.style.top       = coords[1] + dim.height + "px";
    div.style.maxHeight = this.options.maxHeight + "px";
    div.style.minWidth  = this.options.minWidth + "px";

    // insert into DOM
    document.body.appendChild(div);

    // simulate maxHeight/minWidth on MSIE (must be AFTER appendChild())
    if (navigator.appVersion.match(/\bMSIE\b/)) {
      div.style.setExpression("height", 
        "this.scrollHeight>" + this.options.maxHeight + "?" + this.options.maxHeight + ":'auto'");
      div.style.setExpression("width", 
        "this.scrollWidth<" + this.options.minWidth + "?" + this.options.minWidth + ":'auto'");
    }

    return this.dropdownDiv = div;
  },



  _displayChoices: function() {
    if (!this.choices) {
      var asynch = this.updateChoices();
      if (asynch) return; // updateChoices() is responsible for calling back
    }
    if (this.choices.length > 0) {
      var ac = this;
      var cl = this.choiceList = new GvaScript.ChoiceList(this.choices, {
        labelField : this.options.labelField
        });

      cl.onHighlight = function(event) {
        if (ac.options.typeAhead) 
          ac._typeAhead();
        ac.fireEvent(event, ac.inputElement);
      };
      cl.onPing = function(event) {
        ac._completeFromChoiceElem(event.target);
      };
      cl.onCancel = function(event) {
        ac._removeDropdownDiv();
      };

      // fill container now so that the keymap gets initialized
      cl.fillContainer(this._mkDropdownDiv());

      // playing with the keymap: when tabbing, should behave like RETURN
      cl.keymap.rules[0].TAB = cl.keymap.rules[0].S_TAB = function(event) {
        var index = cl.currentHighlightedIndex;
        if (index != undefined) {
          var elem = cl._choiceElem(index);
          cl.fireEvent({type : "Ping", 
                        index: index}, elem, cl.container);
          // NO Event.stop() here
        }
      };

      // more key handlers when the suggestion list is displayed
      this.keymap.rules.push(cl.keymap.rules[0]);

    }
    else 
      this.displayMessage("pas de suggestion");
  },


  _removeDropdownDiv: function(event) { // may be choices div or message div
    if (this.keymap.rules.length > 1)
      this.keymap.rules.pop(); // remove navigationRules

    if (this.dropdownDiv) {
      Element.remove(this.dropdownDiv);
      this.dropdownDiv = null;
    }
    if (event) Event.stop(event);
  },


  _valueFromChoice: function(index) {
    if (!this.choices || this.choices.length < 1) return null;
    var choice = this.choices[index];
    return (typeof choice == "string") ? choice 
                                       : choice[this.options.valueField];
  },



  _completeFromChoiceElem: function(elem) {
    var num = parseInt(elem.id.match(/\.(\d+)$/)[1], 10);

    var choice = this.choices[num];
    if (!choice) throw new Error("choice number is out of range : " + num);
    var value = this._valueFromChoice(num);
    if (value) {
      this.inputElement.value = this.lastValue = value;
      this.inputElement.jsonValue = choice;
      this._removeDropdownDiv();
      this.inputElement.select();
      this.fireEvent({type: "Complete", index: num}, elem, this.inputElement); 
    }
    // else WHAT ??
    //    - might have other things to trigger (JS actions / hrefs)
  }

}

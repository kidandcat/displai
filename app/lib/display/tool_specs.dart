/// MCP tool definitions for the display (names, descriptions, JSON Schemas).
///
/// The schemas are deliberately small: every token here is sent with each
/// request and every token the model writes into a tool call costs latency.
library;

/// One MCP tool exposed by the display.
class DisplayToolSpec {
  const DisplayToolSpec({
    required this.name,
    required this.description,
    required this.inputSchema,
  });

  final String name;
  final String description;
  final Map<String, dynamic> inputSchema;

  Map<String, dynamic> toJson() => {
    'name': name,
    'description': description,
    'inputSchema': inputSchema,
  };
}

const String _nodeTypesDoc =
    'Node types: heading{text} | text{text; **bold** *italic*} | '
    'cards{items:[{title,subtitle?,body?,image?,value?}], layout?:list|grid} | '
    'table{columns:[..], rows:[[..]]} | stats{items:[{label,value,delta?}]} | '
    'kv{items:[[key,value]]} | chips{items:[str]} | buttons{items:[label]} | '
    'progress{value 0-1, label?} | image{url, caption?} | video{url, loop?} | '
    'divider | row|column|grid{children:[nodes], cols?} | '
    'html{html, data?, height?} (a custom page inline, see the html tool).';

final Map<String, dynamic> _nodeSchema = {
  'type': 'object',
  'properties': {
    'type': {
      'type': 'string',
      'enum': [
        'heading',
        'text',
        'cards',
        'table',
        'stats',
        'kv',
        'chips',
        'buttons',
        'progress',
        'image',
        'video',
        'html',
        'divider',
        'row',
        'column',
        'grid',
      ],
    },
    'id': {
      'type': 'string',
      'description': 'Optional, to target it in update.',
    },
    'text': {'type': 'string'},
    'items': {'type': 'array', 'description': 'Per type, see above.'},
    'columns': {
      'type': 'array',
      'items': {'type': 'string'},
    },
    'rows': {
      'type': 'array',
      'items': {'type': 'array'},
    },
    'url': {'type': 'string'},
    'caption': {'type': 'string'},
    'label': {'type': 'string'},
    'value': {'type': 'number'},
    'layout': {
      'type': 'string',
      'enum': ['list', 'grid'],
    },
    'cols': {'type': 'integer'},
    'loop': {'type': 'boolean'},
    'html': {'type': 'string'},
    'data': {},
    'height': {'type': 'number'},
    'children': {
      'type': 'array',
      'description': 'Nested nodes (row/column/grid).',
      'items': {'type': 'object'},
    },
  },
  'required': ['type'],
};

/// Where a view pops up as a widget while Minerva works in other apps (the window is the orb).
const Map<String, dynamic> _atSchema = {
  'type': 'string',
  'enum': [
    'top-right',
    'top-left',
    'bottom-right',
    'bottom-left',
    'left',
    'right',
    'center',
  ],
  'description':
      'Where the widget goes while you work in other apps; default '
      'top-right, under the orb. Keep clear of what you act on.',
};

final List<DisplayToolSpec> displayToolSpecs = [
  DisplayToolSpec(
    name: 'show',
    description:
        'Replace the display with a new view (the old one is gone). '
        'body = list of nodes {type, id?, ...}. $_nodeTypesDoc '
        'Cards, table rows, chips and buttons get visible ordinals 1..N in '
        'order, so the user can say "la segunda"; taps and button presses '
        'reach you as "[display] ..." user messages. Image/video urls: https '
        'or file://. Returns the component ids.',
    inputSchema: {
      'type': 'object',
      'properties': {
        'at': _atSchema,
        'title': {'type': 'string', 'description': 'Short view title.'},
        'subtitle': {'type': 'string'},
        'body': {'type': 'array', 'items': _nodeSchema},
      },
      'required': ['title', 'body'],
    },
  ),
  const DisplayToolSpec(
    name: 'update',
    description:
        'Patch the current view in place. id = component id (from show or '
        'get_state). set: props to replace, e.g. {"value":0.8}, '
        '{"text":"..."}, {"rows":[...]}. append: items, rows or child nodes '
        'to add at the end. values: form field values {name: value} '
        '(id = form id). remove: true deletes the component.',
    inputSchema: {
      'type': 'object',
      'properties': {
        'id': {'type': 'string'},
        'set': {'type': 'object'},
        'append': {'type': 'array'},
        'values': {'type': 'object'},
        'remove': {'type': 'boolean'},
      },
      'required': ['id'],
    },
  ),
  const DisplayToolSpec(
    name: 'form',
    description:
        'Show a form as a new view. Returns at once; when the user submits '
        'it you get a "[display] form ... submitted: {values}" message. '
        'Field types: text, number, date (YYYY-MM-DD), select (options), '
        'checkbox, slider (min, max, step). Select options get ordinals.',
    inputSchema: {
      'type': 'object',
      'properties': {
        'title': {'type': 'string'},
        'id': {'type': 'string'},
        'intro': {'type': 'string', 'description': 'Optional text above.'},
        'submit': {'type': 'string', 'description': 'Submit button label.'},
        'fields': {
          'type': 'array',
          'items': {
            'type': 'object',
            'properties': {
              'name': {'type': 'string'},
              'label': {'type': 'string'},
              'type': {
                'type': 'string',
                'enum': [
                  'text',
                  'number',
                  'date',
                  'select',
                  'checkbox',
                  'slider',
                ],
              },
              'options': {
                'type': 'array',
                'items': {'type': 'string'},
              },
              'default': {},
              'required': {'type': 'boolean'},
              'min': {'type': 'number'},
              'max': {'type': 'number'},
              'step': {'type': 'number'},
              'placeholder': {'type': 'string'},
            },
            'required': ['name', 'type'],
          },
        },
      },
      'required': ['title', 'fields'],
    },
  ),
  const DisplayToolSpec(
    name: 'video',
    description:
        'Play a direct video file (mp4, mov, m3u8; https or file://) '
        'full-window. YouTube or other web pages do not work. Without url, '
        'control the current video: control play|pause, seek (seconds).',
    inputSchema: {
      'type': 'object',
      'properties': {
        'url': {'type': 'string'},
        'title': {'type': 'string'},
        'loop': {'type': 'boolean'},
        'control': {
          'type': 'string',
          'enum': ['play', 'pause'],
        },
        'seek': {'type': 'number'},
      },
    },
  ),
  DisplayToolSpec(
    name: 'html',
    description:
        'Show a view you program yourself: an HTML page with its CSS and JS '
        '(canvas, SVG, animations, games, 3D, charts, custom controls; load '
        'libraries from a CDN). Use it when no show node fits. The page fills '
        'the view under the title (full: edge to edge, no title; keep the '
        'top-right corner free, the orb sits there). It gets the display theme '
        'as CSS variables (--bg --surface --border --accent --accent2 --text '
        '--muted --positive --negative; --s = scale, base font 22px*--s) and '
        'a `minerva` object: minerva.data (the data arg); minerva.onData = '
        'fn(data), called when update sets data (no reload); minerva.send(v) '
        'reaches you as a "[display] page ... sent: v" message (use it for '
        'clicks and results); minerva.state(v) shows v in get_state. Returns '
        'once the page loads, with its JS errors: fix them at once. '
        'update {id, set:{data}} pushes new data; set:{html} reloads it.',
    inputSchema: {
      'type': 'object',
      'properties': {
        'at': _atSchema,
        'title': {'type': 'string'},
        'html': {
          'type': 'string',
          'description': 'The page: a body fragment or a whole document.',
        },
        'data': {'description': 'JSON given to the page as minerva.data.'},
        'full': {'type': 'boolean'},
        'id': {'type': 'string', 'description': 'Default page1.'},
      },
      'required': ['html'],
    },
  ),
  const DisplayToolSpec(
    name: 'clear',
    description: 'Clear the display (back to the idle animation).',
    inputSchema: {'type': 'object', 'properties': {}},
  ),
  const DisplayToolSpec(
    name: 'get_state',
    description:
        'What is on screen now: compact tree with component ids, ordinals '
        '[n] of selectable items, form values and recent user actions.',
    inputSchema: {'type': 'object', 'properties': {}},
  ),
];

/// DisplAI display layer: the model-driven screen.
///
/// The integrator only needs this import:
/// - [DisplayController.toolSpecs] to register the display tools with the
///   model, [DisplayController.callTool] to run them and
///   [DisplayController.streamPartial] to render tool calls while they stream;
/// - [DisplayView] to show it;
/// - [DisplayController.userEvents] to feed user interactions back to the
///   model.
library;

export 'display_controller.dart' show DisplayController, DisplayViewEntry;
export 'display_view.dart' show DisplayView;
export 'theme.dart' show DisplayColors, DisplayStrings;
export 'tool_specs.dart' show DisplayToolSpec;

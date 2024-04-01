defmodule WxMVU.Intent do
  @moduledoc """
  Typespecs for render intents.

  Intents are declarative instructions that scenes emit
  and the Renderer applies to the wx environment.
  """

  @type widget_id :: atom() | {atom(), term()}
  @type parent_id :: atom() | {atom(), term()}
  @type window_id :: atom()

  @type opts :: keyword()

  @type widget_type ::
          :static_text
          | :choice
          | :notebook
          | :button
          | :checkbox
          | :text_ctrl

  @type layout_spec ::
          {:vbox, opts(), [widget_id()]}
          | {:hbox, opts(), [widget_id()]}

  @type t ::
          {:ensure_window, window_id(), opts()}
          | {:ensure_panel, widget_id(), parent_id(), opts()}
          | {:ensure_widget, widget_id(), widget_type(), parent_id(), opts()}
          | {:set, widget_id(), props :: keyword()}
          | {:layout, parent_id(), layout_spec()}

  @type intents :: [t()]
end

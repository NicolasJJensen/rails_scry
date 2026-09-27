# Rails responses: HTML, JSON, and Turbo

Scry compiles a filter and returns an `Scry::Result`. It does not choose an
HTTP status, render a template, or provide a form builder. The controller owns
that response policy; `turbo-rails` supplies the Turbo helpers and MIME type.

The example below uses a single root property filter for `User`. Its form uses
real `args[]` names, so Rails receives an array of operands. Do not name the
controls `filter[filters][0]...`: numeric hash keys are parsed as hashes and do
not preserve the filter DSL's array shape.

For an HTML-only application without Turbo, omit the `format.turbo_stream` branch
and stream template, and replace `turbo_frame_tag UsersController::FRAME_ID` with
`content_tag :section, id: UsersController::FRAME_ID`. The same form, errors, and
HTML response then work without the Turbo helpers or JavaScript.

## Controller

The initial GET uses an empty `and` group. That gives Scry a filter node to
compile, so mandatory model scopes still apply. A submitted filter is retained
for rendering whether compilation succeeds, is partial, or fails.

`app/controllers/users_controller.rb`:

```ruby
class UsersController < ApplicationController
  FRAME_ID = "users_search"

  def index
    records = User.where(organisation: current_organisation)
    @result = search_result(records)
    @users = @result.success? ? @result.relation : @result.relation.none
    @errors_by_path = @result.diagnostics.group_by(&:path)
    status = @response_status || (@result.success? ? :ok : :unprocessable_entity)

    respond_to do |format|
      format.html { render :index, status: status }
      format.turbo_stream { render :index, status: status }
      format.json do
        if @result.success?
          render json: @users.as_json(only: [:id, :first_name])
        else
          render json: { errors: @result.diagnostics.map(&:to_h) }, status: status
        end
      end
    end
  end

  private

  def search_result(records)
    raw = params[:filter]
    @filter = raw.is_a?(ActionController::Parameters) ? raw.to_unsafe_h : {}

    if !raw.nil? && !raw.is_a?(ActionController::Parameters)
      @response_status = :bad_request
      return Scry::Result.failure(
        relation: records.none,
        code: :invalid_filter,
        message: "Filter must be an object",
        path: []
      )
    end

    filter = raw.nil? ? { type: "group", predicate: "and", filters: [] } : @filter
    Scry.filter_records_by(records: records, filter: filter, context: current_user)
  rescue Scry::FilterError => error
    raise unless error.result

    error.result
  end
end
```


This assumes the application provides `current_user`, `current_organisation`,
and a `User` model belonging to an organisation. Start with the relation your
application authorizes. Registered mandatory model scopes also run, including
on the initial page load. Add `resources :users, only: :index` to the application's
routes if it does not already have an index route.

The controller rejects both partial and failed filters with HTTP 422. Malformed
non-object payloads return HTTP 400 through the same templates, including the
matching frame. It retains `@filter` for correction and never displays the
relation from a rejected filter. With `invalid_filter_policy: :raise`, the rescue
uses `error.result`; unrelated exceptions, including callback exceptions without
a result, remain visible to the application's error handling.

If the endpoint accepts JSON as well as form data, the JSON body should contain
the same object shape. `to_unsafe_h` is used only to pass this nested filter
language to Scry; it is not a general authorization bypass. Scry validates the
filter and applies its permissions, while the relation and model scopes remain
the host's authorization boundary.

## HTML and Turbo Frame partial

Render the same outer frame for the ordinary HTML request and for a Turbo
stream replacement. Keeping the form, summary, field errors, and results in
one frame preserves submitted values and makes a replacement complete.

`app/views/users/index.html.erb`:

```erb
<%= render "search_frame" %>
```

`app/views/users/_search_frame.html.erb`:

```erb
<%= turbo_frame_tag UsersController::FRAME_ID do %>
  <%= form_with url: users_path, method: :get, scope: :filter,
        data: { turbo_frame: UsersController::FRAME_ID } do |form| %>
    <%= form.hidden_field :type, value: "property" %>
    <% property_path = [:property] %>
    <% predicate_path = [:predicate] %>
    <% args_path = [:args] %>

    <%= form.label :property, "Field", for: "filter_property" %>
    <% property_errors = filter_errors(@errors_by_path, *property_path) %>
    <%= form.text_field :property,
          value: @filter.fetch("property", "first_name"),
          id: "filter_property",
          class: ("is-invalid" if property_errors.any?),
          aria: { invalid: property_errors.any?, describedby: ("filter_property_error" if property_errors.any?) } %>
    <%= render "field_errors", id: "filter_property_error", errors: property_errors if property_errors.any? %>

    <%= form.label :predicate, "Comparison", for: "filter_predicate" %>
    <% predicate_errors = filter_errors(@errors_by_path, *predicate_path) %>
    <%= form.text_field :predicate,
          value: @filter.fetch("predicate", "eq"),
          id: "filter_predicate",
          class: ("is-invalid" if predicate_errors.any?),
          aria: { invalid: predicate_errors.any?, describedby: ("filter_predicate_error" if predicate_errors.any?) } %>
    <%= render "field_errors", id: "filter_predicate_error", errors: predicate_errors if predicate_errors.any? %>

    <%= form.label :args, "Value", for: "filter_args_0" %>
    <% value_errors = filter_errors(@errors_by_path, *args_path, 0) %>
    <% value_errors += filter_errors(@errors_by_path, *args_path, descendants: false) %>
    <% args = @filter["args"] %>
    <%= form.text_field :args, name: "filter[args][]", id: "filter_args_0",
          value: args.is_a?(Array) ? args.first : args,
          class: ("is-invalid" if value_errors.any?),
          aria: { invalid: value_errors.any?, describedby: ("filter_args_0_error" if value_errors.any?) } %>
    <%= render "field_errors", id: "filter_args_0_error", errors: value_errors.uniq if value_errors.any? %>

    <%= form.submit "Search" %>
  <% end %>

  <%= render "summary", result: @result %>

  <% if @result.success? %>
    <ul>
      <% @users.each do |user| %>
        <li><%= user.first_name %></li>
      <% end %>
    </ul>
  <% end %>
<% end %>
```

`app/views/users/_field_errors.html.erb`:

```erb
<div id="<%= id %>" role="alert">
  <% errors.each do |diagnostic| %>
    <p><%= diagnostic.message %></p>
  <% end %>
</div>
```

The form uses `filter[args][]`, which becomes `{"args" => [value]}` after
Rails parameter parsing. Add more value controls with the same name and a
distinct id. For a two-bound `between` predicate, use two `filter[args][]`
inputs and map `[:args, 0]` and `[:args, 1]` separately.

`app/views/users/_summary.html.erb`:

```erb
<% if result.success? %>
  <p role="status"><%= @users.empty? ? "No users found." : "#{@users.size} users found." %></p>
<% else %>
  <p role="alert">The search could not be applied.</p>
  <%= render "diagnostics", diagnostics: result.diagnostics %>
<% end %>
```

`app/views/users/_diagnostics.html.erb`:

```erb
<div role="alert">
  <% diagnostics.each do |diagnostic| %>
    <p><%= diagnostic.message %></p>
  <% end %>
</div>
```

Style the `is-invalid` class in the host application to make invalid controls visually distinct.

The failed branch must not say “0 users found”: an empty relation from a failed
filter is an error result, not a successful no-match search.

## Turbo Streams

`app/views/users/index.turbo_stream.erb` replaces the same frame id and renders
the partial that includes the outer `turbo_frame_tag`:

```erb
<%= turbo_stream.replace UsersController::FRAME_ID do %>
  <%= render "search_frame" %>
<% end %>
```

The form above uses an HTML Turbo Frame response. To use Turbo Streams instead,
change its data options to:

```ruby
data: { turbo_frame: UsersController::FRAME_ID, turbo_stream: true }
```

`data-turbo-stream="true"` opts a GET form into the stream MIME type. Both formats
use the same status, result policy, form values, and errors. The stream replaces
`users_search` with a partial containing the outer frame, preserving the target
for subsequent searches. With Turbo disabled, the HTML response renders a normal
page. The host application must load Turbo's JavaScript for frame or stream updates.

Turbo Frame and Stream helpers come from `turbo-rails`, which the application
must install and configure. Scry only returns relations and diagnostics; it is
not a response or Turbo framework.

The [Turbo Frames handbook](https://turbo.hotwired.dev/handbook/frames) explains
why the response must contain the matching frame. The [Turbo Streams handbook](https://turbo.hotwired.dev/handbook/streams)
documents the GET stream opt-in used here. For a non-stream form submission,
follow Turbo's [422 validation response guidance](https://turbo.hotwired.dev/handbook/drive#redirecting-after-a-form-submission).

## Mapping diagnostic paths to fields

Diagnostics follow the submitted filter tree. A root property filter uses:

| Path | Control |
| --- | --- |
| `[:property]` | Field selector |
| `[:predicate]` | Comparison selector |
| `[:args]` | Argument arity or container error |
| `[:args, 0]` | First argument value |

A child of a group adds its array location, for example
`[:filters, 1, :args, 0]`. Nested association or aggregate scoping adds
`:scoping`, and nested children continue below that prefix. The same strategy
works for computed expressions (`:expression`, `:operands`, and operand indexes).

Keep the submitted filter hash in the controller and group diagnostics by
path:

```ruby
@errors_by_path = result.diagnostics.group_by(&:path)
```

The helper used by the partial matches a path prefix, so errors inside a
collection argument still mark that value control. Query `:args` with `descendants: false` for
argument-list errors, so a second argument error does not mark the first input.

`app/helpers/users_helper.rb`:

```ruby
module UsersHelper
  def filter_errors(errors_by_path, *path, descendants: true)
    errors_by_path.flat_map do |error_path, diagnostics|
      matches = error_path == path || (descendants && error_path.first(path.length) == path)
      matches ? diagnostics : []
    end.uniq
  end
end
```

For a root property form, render both `filter_errors(errors, :args, 0)` and
`filter_errors(errors, :args, descendants: false)` beside the value control. Set `aria-invalid="true"`
when either returns an error and point `aria-describedby` at the rendered error
element. Keep labels' `for` attributes aligned with the generated input ids.

For nested group controls, pass the full child path into the partial rather than
inferring it from a field name. Use unique control IDs derived from the path,
such as `filter_filters_1_args_0`. A dynamic group builder must serialize the
`filters` array explicitly; avoid assuming numeric Rails parameter keys produce
an array. The single-property form above supports one value argument; build
additional controls when exposing zero-argument, range, or collection predicates.

This example uses text inputs for the property and predicate so even an invalid
submitted name remains visible for correction. A production filter builder can
use [capability discovery](discovery.md) for selectors. Preserve rejected selections
when re-rendering rather than silently selecting a different valid option.

See the [result and diagnostic contract](configuration.md#configuration),
[field-level error guidance](configuration.md#field-level-errors), and the
[filter reference](filters.md) for the underlying result policies and payload
shapes.

[Back to the README](../README.md#handling-invalid-filters)

# frozen_string_literal: true

class ComparisonController < ActionController::Base
  # Local single-user demo: skip CSRF so the action buttons need no token.
  skip_forgery_protection

  before_action :load_dashboard
  helper_method :scenario_status

  def index
    render :index
  end

  def raw
    @result = DemoComparison::Runner.raw(scenario)
    render :index
  end

  def materialized
    @result = DemoComparison::Runner.materialized(scenario)
    render :index
  end

  def refresh
    @result = DemoComparison::Runner.refresh(scenario)
    render :index
  end

  def mutate
    record = DemoComparison::Mutation.insert_cast_member!
    @notice = "Inserted cast_info ##{record.id}. Views that depend on cast_info are now stale " \
              "until you refresh them — the raw query already reflects the change."
    render :index
  end

  private

  def load_dashboard
    @scenarios = DemoComparison::SCENARIOS
    @dataset = DemoComparison::Dataset.profile
  end

  def scenario
    DemoComparison.find(params[:key]) || raise(ActionController::RoutingError, "unknown scenario: #{params[:key]}")
  end

  def scenario_status(scenario)
    view = scenario.view_class
    return { label: "Not built", css: "muted" } unless view.materialized?
    return { label: "Stale — needs refresh", css: "warn" } if view.dirty?

    { label: "Fresh", css: "ok" }
  end
end

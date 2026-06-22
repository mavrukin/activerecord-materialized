# frozen_string_literal: true

class ComparisonController < ActionController::Base
  # Local single-user demo: skip CSRF so the action buttons need no token.
  skip_forgery_protection

  before_action :sync_database
  before_action :load_dashboard
  helper_method :scenario_status

  def index
    render :index
  end

  # Run the scenario both ways (raw vs. the view) and show them side by side.
  def compare
    @active = scenario.key
    @comparison = DemoComparison::Runner.compare(scenario)
    render :index
  end

  def refresh
    @active = scenario.key
    result = DemoComparison::Runner.refresh(scenario)
    @notice = "#{result[:verb]} #{scenario.label}: #{helpers.number_with_delimiter(result[:row_count])} " \
              "rows materialized in #{result[:ms]} ms. Reads now hit the cache table."
    render :index
  end

  def mutate
    @active = scenario.key
    inserted = DemoComparison::Mutation.insert_cast_members!
    @notice = "Inserted #{inserted} cast_info row(s). Every view that depends on cast_info is now " \
              "stale — Compare to see the raw query reflect the change while the cache holds the old " \
              "value, then Build / refresh to catch up."
    render :index
  end

  def reset
    @active = scenario.key
    DemoComparison::Runner.unbuild(scenario)
    @notice = "Dropped the #{scenario.label} cache table. The view is cold again — Compare to watch " \
              "the read fall through to the source query."
    render :index
  end

  def select_db
    target = DemoComparison::Database.available.find { |db| db[:path] == params[:path] }
    if target
      DemoComparison::Database.use!(target[:path])
      session[:db_path] = DemoComparison::Database.current_path
    end
    redirect_to root_path
  end

  private

  def sync_database
    chosen = session[:db_path]
    DemoComparison::Database.use!(chosen) if chosen && File.file?(chosen)
  end

  def load_dashboard
    @scenarios = DemoComparison::SCENARIOS
    @dataset = DemoComparison::Dataset.profile
    @databases = DemoComparison::Database.available
  end

  def scenario
    DemoComparison.find(params[:key]) || raise(ActionController::RoutingError, "unknown scenario: #{params[:key]}")
  end

  def scenario_status(scenario)
    view = scenario.view_class
    return { label: "Not built — reads fall through to the source", css: "muted" } unless view.materialized?
    return { label: "Stale — needs refresh", css: "warn" } if view.dirty?

    { label: "Fresh — served from cache", css: "ok" }
  end
end

# frozen_string_literal: true

class ComparisonController < ActionController::Base
  # ActionController::Base does not auto-apply the application layout the way a
  # generated ApplicationController does, so declare it (without it, the inline
  # stylesheet in the layout never reaches the page).
  layout "application"

  # Local single-user demo: skip CSRF so the action buttons need no token.
  skip_forgery_protection

  before_action :sync_database
  before_action :load_dashboard, except: :status
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
    @notice = "Inserted #{inserted} cast_info row(s). Every dependent view is now out of sync and is " \
              "refreshing itself in the background — watch the status go syncing → up to date, then " \
              "Compare to confirm the cache caught up."
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

  # Lightweight JSON used by the page to poll each view's freshness, so the
  # status pills can show "out of sync → syncing → up to date" as the background
  # refresh runs — without reloading the page.
  def status
    payload = DemoComparison::SCENARIOS.to_h do |scn|
      DemoComparison.ensure_refresh_progress(scn)
      [scn.key, scenario_status(scn).slice(:label, :css, :state)]
    end
    render json: payload
  end

  private

  def sync_database
    chosen = session[:db_path]
    DemoComparison::Database.use!(chosen) if chosen && File.file?(chosen)
  end

  def load_dashboard
    @scenarios = DemoComparison::SCENARIOS
    @dataset = DemoComparison::Dataset.profile
    @databases = DemoComparison::Database.datasets
  end

  def scenario
    DemoComparison.find(params[:key]) || raise(ActionController::RoutingError, "unknown scenario: #{params[:key]}")
  end

  def scenario_status(scenario)
    view = scenario.view_class
    return { label: "Not built — reads fall through to the source", css: "muted", state: "cold" } unless view.materialized?
    return { label: "Syncing… catching up in the background", css: "sync", state: "syncing" } if view.refreshing?
    return { label: "Out of sync — refreshing automatically", css: "sync", state: "dirty" } if view.dirty?

    { label: "Up to date — served from cache", css: "ok", state: "fresh" }
  end
end

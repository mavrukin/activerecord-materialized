# frozen_string_literal: true

module ActiveRecord
  module Materialized
  class View < ::ActiveRecord::Base
    include RefreshCallbacks

    self.abstract_class = true

    class << self
      attr_reader :source_definition, :max_staleness_setting, :dependency_tables

      def inherited(subclass)
        super
        subclass.instance_variable_set(:@dependency_tables, [])
        subclass.instance_variable_set(:@refresh_strategy, nil)
        subclass.instance_variable_set(:@refresh_debounce, nil)
      end

      def view_key
        return name.underscore if name.present?

        if instance_variable_defined?(:@table_name) && @table_name.present?
          @table_name
        else
          "anonymous_view_#{object_id}"
        end
      end

      def materialized_from(sql = nil, &block)
        @source_definition = sql || block
        Registry.register(self) unless abstract_class?
      end

      alias source materialized_from

      def depends_on(*tables)
        DependencyRegistry.register(self, tables)
      end

      # Refresh when declared dependency tables change.
      # :async     - refresh after commit, debounced (default; mimics NOTIFY + worker)
      # :immediate - refresh synchronously on each change (blocks writers)
      # :manual    - only mark dirty; use refresh! or rake tasks explicitly
      def refresh_on_change(strategy = :async)
        @refresh_strategy = strategy.to_sym
      end

      def refresh_debounce(seconds)
        @refresh_debounce = seconds
      end

      def resolved_refresh_strategy
        @refresh_strategy || ActiveRecord::Materialized.configuration.default_refresh_strategy
      end

      def resolved_refresh_debounce
        interval = @refresh_debounce.nil? ? ActiveRecord::Materialized.configuration.default_refresh_debounce : @refresh_debounce
        interval.respond_to?(:to_f) ? interval.to_f : interval.to_i
      end

      def max_staleness(duration = nil, &block)
        @max_staleness_setting = duration || block
      end

      def resolved_max_staleness
        setting = @max_staleness_setting
        return ActiveRecord::Materialized.configuration.default_max_staleness if setting.nil?
        return instance_eval(&setting) if setting.is_a?(Proc)

        setting
      end

      def resolved_source_sql
        sql = source_definition
        if sql.is_a?(Proc)
          sql = sql.lambda? ? sql.call : instance_eval(&sql)
        end
        sql = sql.call if sql.respond_to?(:call) && !sql.is_a?(String)
        raise ArgumentError, "materialized_from SQL is required for #{name || view_key}" if sql.nil? || sql.strip.empty?

        sql
      end

      def metadata
        @metadata ||= Metadata.new(self)
      end

      def stale?
        metadata.stale?
      end

      def dirty?
        metadata.dirty?
      end

      def last_refreshed_at
        metadata.last_refreshed_at
      end

      def refreshing?
        metadata.refreshing?
      end

      def mark_dependencies_changed!
        metadata.mark_dirty!
      end

      def needs_refresh?
        return true unless table_exists?
        return true if metadata.last_refreshed_at.nil?
        return true if metadata.dirty?

        max_staleness = resolved_max_staleness
        return false if max_staleness.nil?

        metadata.stale?(max_staleness: max_staleness)
      end

      def refresh!(force: false)
        Thread.current[:ar_materialized_refreshing] = true
        Refresher.new(self).refresh!(force: force)
      ensure
        Thread.current[:ar_materialized_refreshing] = false
      end

      def refresh_if_stale!(force: false)
        refresh!(force: force) if needs_refresh?
      end

      def table_exists?
        connection.data_source_exists?(table_name)
      end

      def all(...)
        ensure_materialized!
        super
      end

      def where(...)
        ensure_materialized!
        super
      end

      def find(...)
        ensure_materialized!
        super
      end

      def find_by(...)
        ensure_materialized!
        super
      end

      def count(...)
        ensure_materialized!
        super
      end

      private

      def ensure_materialized!
        return if table_exists?
        return if Thread.current[:ar_materialized_refreshing]

        refresh!
      end
    end

    def stale?
      self.class.stale?
    end
  end
  end
end

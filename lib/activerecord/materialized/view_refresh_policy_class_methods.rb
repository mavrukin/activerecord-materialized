# frozen_string_literal: true

module ActiveRecord
  module Materialized
    # Refresh-policy DSL mixed into a {View}: `refresh_on_change`, `refresh_debounce`, `cold_read`,
    # `warm_up`, `max_staleness`, plus `warm_up!`.
    module ViewRefreshPolicyClassMethods
      def self.included(base)
        base.extend(ClassMethods)
      end

      # The refresh-policy DSL methods available on a {View} subclass.
      module ClassMethods
        def view_class
          self
        end

        # Sets the strategy used to refresh the view when a dependency changes.
        #
        # @param strategy [Symbol] one of +:async+ (default), +:immediate+, or +:manual+
        # @raise [ArgumentError] if +strategy+ is not a known refresh strategy
        # @return [void]
        def refresh_on_change(strategy = :async)
          strategy = strategy.to_sym
          unless RefreshScheduler::STRATEGIES.include?(strategy)
            raise ArgumentError,
                  "unknown refresh strategy #{strategy.inspect}; expected one of #{RefreshScheduler::STRATEGIES.inspect}"
          end

          @refresh_strategy = strategy
        end

        # Sets how long successive async refreshes are coalesced before one runs.
        #
        # @param seconds [Numeric, ActiveSupport::Duration] the debounce interval
        # @return [void]
        def refresh_debounce(seconds)
          @refresh_debounce = seconds
        end

        # Sets how reads are served before the view has been materialized.
        #
        # @param strategy [Symbol] one of +:read_through+ (default), +:serve_stale+, or +:raise+
        # @return [void]
        def cold_read(strategy)
          @cold_read_strategy = strategy.to_sym
        end

        def resolved_cold_read_strategy
          @cold_read_strategy ||
            ActiveRecord::Materialized.configuration.default_cold_read_strategy
        end

        # Selects where this view's changes come from: +:callbacks+ (the default
        # built-in tracker installs commit callbacks on +depends_on+ models) or
        # +:none+ (install no callbacks; feed changes through the public
        # ingestion API from an external adapter — e.g. a CDC stream).
        #
        # Setting +:callbacks+ (re)installs callbacks for any dependencies already
        # declared, so it works regardless of whether it precedes or follows
        # +depends_on+ — important when the global default is +:none+.
        #
        # @param source [Symbol] +:callbacks+ or +:none+
        # @return [void]
        def change_source(source)
          @change_source = ChangeSource.cast(source)
          DependencyRegistry.install_callbacks_for(view_class) if @change_source == ChangeSource::CALLBACKS
        end

        def resolved_change_source
          @change_source ||
            ActiveRecord::Materialized.configuration.default_change_source
        end

        # Queries warm_up! runs to materialize a cold view's hot partitions, e.g.:
        #   warm_up { [where(region: "us"), order(revenue: :desc).limit(50)] }
        #
        # @yieldreturn [Array<ActiveRecord::Relation>] the relations whose partitions to warm
        # @return [void]
        def warm_up(&block)
          @warm_up_definition = block
        end

        def resolved_warm_up_queries
          block = @warm_up_definition
          return [] if block.nil?

          Kernel.Array(view_class.instance_eval(&block))
        end

        # Running each warm_up query enqueues scoped maintenance for the
        # partitions it touches; refresh! then applies it.
        def warm_up!
          resolved_warm_up_queries.each(&:to_a)
          view_class.refresh!
        end

        def resolved_refresh_strategy
          @refresh_strategy || ActiveRecord::Materialized.configuration.default_refresh_strategy
        end

        def resolved_refresh_debounce
          interval = if @refresh_debounce.nil?
                       ActiveRecord::Materialized.configuration.default_refresh_debounce
                     else
                       @refresh_debounce
                     end
          interval.respond_to?(:to_f) ? interval.to_f : interval.to_i
        end

        # Sets the maximum staleness window before the view is treated as stale — a static
        # duration, or a block evaluated in the view's context for a dynamic window.
        #
        # @param duration [Numeric, ActiveSupport::Duration, nil] a static staleness window
        # @yieldreturn [Numeric, ActiveSupport::Duration] a dynamically computed staleness window
        # @return [void]
        def max_staleness(duration = nil, &block)
          @max_staleness_setting = duration || block
        end

        def resolved_max_staleness
          setting = @max_staleness_setting
          default = ActiveRecord::Materialized.configuration.default_max_staleness
          return default if setting.nil?
          return view_class.instance_eval(&setting) if setting.is_a?(Proc)

          setting
        end
      end
    end
  end
end

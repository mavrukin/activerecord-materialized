# frozen_string_literal: true

module ActiveRecord
  module Materialized
    # Eager-loads the view classes under {Configuration#view_load_paths} so their +depends_on+ commit
    # callbacks are installed even under Zeitwerk's lazy loading (development/test). Invoked by the
    # Railtie on boot and on each code reload (via +config.to_prepare+); idempotent.
    #
    # Without this, a view whose constant nothing has referenced yet is dormant — its +after_*_commit+
    # hooks are never installed — so writes to its dependencies silently don't schedule maintenance
    # until something first touches the class. In production (+config.eager_load = true+) every view
    # already loads at boot, so this is a no-op there.
    #
    # @api private
    class ViewLoader
      class << self
        # Load the configured view directories through Zeitwerk. A no-op outside Rails or when
        # {Configuration#view_load_paths} is empty.
        #
        # @return [void]
        def load!
          return unless rails_application?

          autoloader = ::Rails.autoloaders.main
          ActiveRecord::Materialized.configuration.view_load_paths.each do |path|
            absolute = ::Rails.root.join(path).to_s
            eager_load_dir(autoloader, absolute) if File.directory?(absolute)
          end
        end

        private

        def rails_application?
          defined?(::Rails) && ::Rails.respond_to?(:application) && ::Rails.application
        end

        # Eager-load one directory through Zeitwerk so the view constants under it load and install
        # their callbacks. +eager_load_dir+ is Rails' own mechanism — idempotent and reload-safe — but
        # it raises for a directory this autoloader does not manage (an engine path, a non-autoloaded
        # location), which is not ours to load, so that is ignored.
        def eager_load_dir(autoloader, absolute)
          autoloader.eager_load_dir(absolute)
        rescue ::Zeitwerk::Error
          nil
        end
      end
    end
  end
end

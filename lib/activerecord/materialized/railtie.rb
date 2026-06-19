# frozen_string_literal: true

module ActiveRecord
  module Materialized
  class Railtie < Rails::Railtie
    rake_tasks do
      load File.expand_path("tasks.rb", __dir__)
    end

    initializer "activerecord_materialized.install" do
      ActiveSupport.on_load(:active_record) do
        ActiveRecord::Materialized::InstallHooks.install!
      end
    end
  end
  end
end

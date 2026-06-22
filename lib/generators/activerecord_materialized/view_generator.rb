# typed: strict
# frozen_string_literal: true

require "rails/generators"

module ActiverecordMaterialized
  # `rails generate activerecord_materialized:view NAME` — scaffolds a materialized view class.
  class ViewGenerator < ::Rails::Generators::NamedBase
    extend T::Sig

    source_root File.expand_path("templates", __dir__)

    sig { void }
    def create_model
      template "materialized_view.rb.erb", File.join("app/models", class_path, "#{file_name}.rb")
    end
  end
end

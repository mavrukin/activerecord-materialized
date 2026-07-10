# typed: strict
# frozen_string_literal: true

# Shims for constants shadowed by nested `module ActiveRecord::Materialized` definitions.

class ::ActiveRecord::Materialized::MetadataRecord < ::ActiveRecord::Base
  sig { returns(T.nilable(String)) }
  def view_name; end

  sig { returns(T.nilable(::ActiveRecordMaterializedTypes::Timestamp)) }
  def last_refreshed_at; end

  sig { returns(T.nilable(T::Boolean)) }
  def refreshing?; end

  sig { returns(T.nilable(T::Boolean)) }
  def dirty?; end

  sig { returns(T.nilable(T::Boolean)) }
  def warm?; end

  sig { returns(T.nilable(Integer)) }
  def row_count; end

  sig { returns(T.nilable(Integer)) }
  def refresh_duration_ms; end

  sig { returns(T.nilable(::ActiveRecordMaterializedTypes::Timestamp)) }
  def last_reconciled_at; end

  sig { returns(T.nilable(Integer)) }
  def reconciled_partition_count; end

  sig { returns(T.nilable(String)) }
  def last_error; end

  sig { params(attributes: T.untyped).returns(T::Boolean) }
  def update!(attributes); end
end

class ::ActiveRecord::Materialized::View
  class << self
    include ::ActiveRecord::Materialized::RefreshCallbacks::ClassMethods
  end
end

module ::ActiveRecord::Materialized::RefreshCallbacks::ClassMethods
  include ::Kernel
end

module ::ActiveRecord::Materialized::DependencyTrackable
  class << self
    extend T::Sig

    sig { params(model_class: T.class_of(::ActiveRecord::Base)).void }
    def subscribe(model_class); end

    sig { void }
    def reset!; end
  end
end

module ::ActiveJob
  class Base < ::Object
    sig { params(block: T.proc.returns(T.any(Symbol, String))).void }
    def self.queue_as(&block); end

    sig { params(args: T.untyped).returns(T.untyped) }
    def self.perform_later(*args); end
  end
end

module ::Rails
  class Railtie < ::Object
    sig { params(block: T.proc.void).void }
    def self.rake_tasks(&block); end

    sig { params(name: String, block: T.proc.void).void }
    def self.initializer(name, &block); end
  end

  module Generators
    class Base < ::Object
      sig { params(path: String).void }
      def self.source_root(path); end

      sig { returns(Symbol) }
      def behavior; end

      sig { params(name: String).void }
      def readme(name); end

      sig { params(source: String, destination: String).void }
      def migration_template(source, destination); end
    end

    class NamedBase < ::Rails::Generators::Base
      sig { returns(T::Array[String]) }
      def class_path; end

      sig { returns(String) }
      def class_name; end

      sig { returns(String) }
      def file_name; end

      sig { params(source: String, destination: String).void }
      def template(source, destination); end
    end

    module Migration
      sig { params(dirname: String).returns(Integer) }
      def self.current_migration_number(dirname); end
    end
  end
end

class ::ActiveRecord::Migration
  sig { params(number: T.any(Integer, String)).returns(String) }
  def self.next_migration_number(number); end
end

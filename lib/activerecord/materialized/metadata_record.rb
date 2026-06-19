# typed: strict
# frozen_string_literal: true

module ActiveRecord
  module Materialized
    class MetadataRecord < ::ActiveRecord::Base
      extend T::Sig

      @table_name_override = T.let(nil, T.nilable(String))

      self.table_name = ::ActiveRecord::Materialized.metadata_table_name

      sig { params(name: String).void }
      def self.table_name=(name)
        @table_name_override = name
      end

      sig { returns(String) }
      def self.table_name
        override = @table_name_override
        override.nil? ? ::ActiveRecord::Materialized.metadata_table_name : override
      end
    end
  end
end

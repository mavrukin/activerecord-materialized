# typed: strict
# frozen_string_literal: true

module ActiveRecord
  module Materialized
    module ViewSourceDefinition
      extend T::Sig

      module_function

      sig do
        params(
          view: T.class_of(View),
          definition: T.nilable(SourceDefinition)
        ).returns(T.nilable(String))
      end
      def resolve(view, definition)
        sql = definition
        sql = evaluate(view, sql) if sql.is_a?(Proc)
        sql = T.unsafe(sql).call if sql.respond_to?(:call) && !sql.is_a?(String)
        sql
      end

      sig { params(view: T.class_of(View), definition: Proc).returns(T.nilable(String)) }
      def evaluate(view, definition)
        return definition.call if definition.lambda?

        T.unsafe(view).instance_eval(&definition)
      end

      sig { params(view: T.class_of(View), sql: String).void }
      def validate!(view, sql)
        return unless sql.strip.empty?

        Kernel.raise ArgumentError, "materialized_from SQL is required for #{view.name || view.view_key}"
      end
    end
  end
end

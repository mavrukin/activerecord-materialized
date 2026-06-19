# typed: strict
# frozen_string_literal: true

module ActiveRecordMaterializedTypes
  DebounceInterval = T.type_alias { T.any(Integer, Float, ::ActiveSupport::Duration) }
  StalenessDuration = T.type_alias { T.any(Integer, ::ActiveSupport::Duration) }
  SourceDefinition = T.type_alias { T.any(String, Proc, T.nilable(T.proc.returns(String))) }
  RefreshCallbackName = T.type_alias { T.any(Symbol, Proc) }
  Connection = T.type_alias { ::ActiveRecord::ConnectionAdapters::AbstractAdapter }
  Timestamp = T.type_alias { T.any(::Time, ::ActiveSupport::TimeWithZone) }
end

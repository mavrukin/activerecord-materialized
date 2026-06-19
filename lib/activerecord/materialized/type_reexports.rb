# typed: strict
# frozen_string_literal: true

module ActiveRecord
  module Materialized
    DebounceInterval = T.type_alias { ::ActiveRecordMaterializedTypes::DebounceInterval }
    StalenessDuration = T.type_alias { ::ActiveRecordMaterializedTypes::StalenessDuration }
    SourceDefinition = T.type_alias { ::ActiveRecordMaterializedTypes::SourceDefinition }
    RefreshMode = T.type_alias { ::ActiveRecordMaterializedTypes::RefreshMode }
    RefreshCallbackName = T.type_alias { ::ActiveRecordMaterializedTypes::RefreshCallbackName }
    Connection = T.type_alias { ::ActiveRecordMaterializedTypes::Connection }
    Timestamp = T.type_alias { ::ActiveRecordMaterializedTypes::Timestamp }
  end
end

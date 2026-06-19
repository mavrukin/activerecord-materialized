# typed: strict
# frozen_string_literal: true

module ActiveRecord
  module Materialized
    ViewClass = T.type_alias { T.class_of(View) }
  end
end

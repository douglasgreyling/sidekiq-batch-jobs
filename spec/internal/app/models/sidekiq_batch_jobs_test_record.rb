# frozen_string_literal: true

# Stands in for a host application's ApplicationRecord. The dummy app points the
# gem at this so the whole suite runs against a *non-default* base class — which
# is what makes "the models inherit from the configured base" a real assertion
# rather than one that passes trivially because the default is ActiveRecord::Base.
class SidekiqBatchJobsTestRecord < ActiveRecord::Base
  self.abstract_class = true
end

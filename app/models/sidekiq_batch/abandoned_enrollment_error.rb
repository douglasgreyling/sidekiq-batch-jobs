# frozen_string_literal: true

class SidekiqBatch
  class AbandonedEnrollmentError < StandardError
    def initialize
      super("the jobs {} block never finished enrolling — the process running it did not survive")
    end
  end
end

# frozen_string_literal: true

require_relative "base"

module ISMS
  module Connectors
    # 人事系统适配器：输出人员主数据（入职/离职状态与离职生效时间）
    class HRConnector < Base
      def normalize
        records_of_type("employee").map do |r|
          Canonical::Person.new(
            person_id: r["id"],
            name: r["name"],
            email: r["email"],
            status: r["employment_status"],
            termination_at: r["termination_date"] && Time.parse(r["termination_date"])
          )
        end      end
    end
  end
end

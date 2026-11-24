# frozen_string_literal: true

require "time"
require_relative "../support/time_range"

module ISMS
  module Engine
    # 单项控制在整个审核周期上的评估结果。
    #
    # segments：时间轴分段（连续符合性的核心证据），每段都有
    #   status   —— effective(有效) / violated(违规) / gap(数据缺口) / exempted(已豁免)
    #   range    —— 半开区间，全部段拼接后恰好覆盖整个审核周期
    #   evidence —— 机器可读证据（原始记录引用、工单号等）
    # findings：点式发现（如某次未评审合并），与区间式分段并存
    class ControlResult
      STATUSES = %w[effective violated gap exempted not_applicable].freeze

      attr_accessor :control_id, :control_name, :standard_ref, :rule_version,
                    :status, :segments, :findings, :coverage_gaps, :summary,
                    :exceptions_applied, :evaluated_at

      def initialize(control_id:, control_name:, standard_ref:, rule_version:)
        @control_id = control_id
        @control_name = control_name
        @standard_ref = standard_ref
        @rule_version = rule_version
        @segments = []
        @findings = []
        @coverage_gaps = []
        @exceptions_applied = []
        @evaluated_at = Time.now.utc
      end

      # 汇总状态（取最差）：violated > gap > exempted > effective。
      # 注意：豁免不等于合规——周期内存在豁免段时，结论只能是"已豁免"，
      # 若同时存在未豁免的违规段，仍是 violated。
      def roll_up!
        present = @segments.map { |s| s["status"] }
        present += @findings.map { |f| f["status"] }
        @status =
          if present.include?("violated")
            "violated"
          elsif present.include?("gap")
            "gap"
          elsif present.include?("exempted")
            "exempted"
          elsif present.empty?
            "not_applicable"
          else
            "effective"
          end
        @summary = build_summary
        self
      end

      def to_h
        {
          "control_id" => @control_id,
          "control_name" => @control_name,
          "standard_ref" => @standard_ref,
          "rule_version" => @rule_version,
          "status" => @status,
          "summary" => @summary,
          "evaluated_at" => @evaluated_at.iso8601,
          "segments" => @segments,
          "findings" => @findings,
          "coverage_gaps" => @coverage_gaps,
          "exceptions_applied" => @exceptions_applied
        }
      end

      private

      def build_summary
        counts = Hash.new(0)
        @segments.each { |s| counts[s["status"]] += 1 }
        hours = Hash.new(0.0)
        @segments.each do |s|
          r = s["range"]
          hours[s["status"]] += (Time.parse(r["end"]) - Time.parse(r["start"])) / 3600.0
        end
        parts = hours.map { |k, v| "#{k}=#{v.round(1)}h" }
        "分段 #{counts}；时长分布 #{parts.join(', ')}；点式发现 #{@findings.size} 项"
      end
    end
  end
end

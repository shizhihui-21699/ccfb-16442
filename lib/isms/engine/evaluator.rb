# frozen_string_literal: true

require "time"
require_relative "../support/time_range"
require_relative "control_result"

module ISMS
  module Engine
    # 评估引擎。输入规范化数据 + 例外窗口 + 审核周期，输出带连续时间轴的控制结果。
    #
    # 设计原则：
    #   1. 不相信任何"当前状态"快照，只用带时间戳的事件流重建历史
    #   2. 审核周期被完整切分覆盖，未被违规/豁免/缺口占据的时间才算有效
    #   3. 豁免只在"控制 + 资源 + 时间"三个维度都匹配时生效，且例外本身必须合法
    class Evaluator
      Context = Struct.new(:period, :people, :accounts, :merge_requests,
                           :patches, :tickets, :exceptions, :connectors,
                           :identity_pending, keyword_init: true)

      HANDLERS = {
        "ACC-01" => :evaluate_offboarding,
        "CR-01"  => :evaluate_code_review,
        "PM-01"  => :evaluate_patch_sla,
        "GOV-01" => :evaluate_identity_mapping
      }.freeze

      def initialize(rule)
        @rule = rule
        @result = ControlResult.new(
          control_id: rule["id"],
          control_name: rule["name"],
          standard_ref: rule["standard_ref"],
          rule_version: rule["version"]
        )
      end

      def run(ctx)
        send(HANDLERS.fetch(@rule["id"]), ctx)
        attach_coverage_gaps(ctx)
        @result.roll_up!
        @result
      end

      private

      # ---- ACC-01：离职员工账号及时禁用 -------------------------------------
      # 判定：离职生效后，每个关联账号在 SLA 小时数内必须出现禁用事件。
      # 违规区间 = [离职时间 + SLA, 实际禁用时间)；未禁用则延伸到周期终点。
      def evaluate_offboarding(ctx)
        sla_hours = @rule.dig("params", "disable_sla_hours")
        ctx.people.select(&:terminated?).each do |person|
          next if person.termination_at.nil? || person.termination_at >= ctx.period.end_time

          # 只评估已可靠映射到该员工的账号；无法映射的账号由 GOV-01 单独报告，
          # 绝不能凭猜测挂到某人名下（会同时制造误报和漏报）。
          ctx.accounts.reject { |a| a.person_id.nil? }
                      .select { |a| a.person_id == person.person_id }
                      .each do |acct|
            ref = "account:#{acct.account_id}"
            deadline = person.termination_at + sla_hours * 3600
            disable_event = acct.status_events.select { |e| e.status == "disabled" }
                             .min_by(&:at)
            disabled_at = disable_event&.at

            # 违规区间起点（禁用期限）若已超出审核周期，本周期内不构成违规
            next if deadline >= ctx.period.end_time

            violation_end = [disabled_at || ctx.period.end_time, ctx.period.end_time].min
            next if deadline >= violation_end

            vrange = ISMS::TimeRange.new(deadline, violation_end)
            apply_with_exceptions(ctx, vrange, resource_ref: ref,
                                  evidence_base: {
                                    "person_id" => person.person_id,
                                    "account" => acct.account_id,
                                    "termination_at" => person.termination_at.iso8601,
                                    "disable_deadline" => deadline.iso8601,
                                    "disabled_at" => disabled_at&.iso8601,
                                    "raw_refs" => ["hr:#{person.person_id}", "account:#{acct.account_id}"]
                                  })
          end
        end
      end

      # ---- CR-01：受保护分支的合并必须经过非作者本人评审 --------------------
      # 点式控制：对周期内每一次合并做判定，例外按 MR 资源引用豁免。
      def evaluate_code_review(ctx)
        ctx.merge_requests.select(&:merged?).each do |mr|
          next unless mr.protected
          next unless mr.merged_at >= ctx.period.start_time && mr.merged_at < ctx.period.end_time

          ref = "mr:#{mr.repo}!#{mr.mr_id}"
          valid_approval = mr.approvals.any? do |a|
            a.reviewer_id != mr.author_id && a.at <= mr.merged_at
          end

          if valid_approval
            @result.findings << {
              "status" => "effective",
              "at" => mr.merged_at.iso8601,
              "resource" => ref,
              "evidence" => {
                "repo" => mr.repo, "mr_id" => mr.mr_id,
                "author_id" => mr.author_id,
                "approver_ids" => mr.approvals.map(&:reviewer_id),
                "raw_refs" => ["gitlab:#{mr.mr_id}"]
              }
            }
            next
          end

          ex = matching_exception(ctx, control_id: @rule["id"], resource_ref: ref,
                                  at: mr.merged_at)
          if ex
            record_exempted_finding(mr.merged_at, ref, ex,
                                    { "repo" => mr.repo, "mr_id" => mr.mr_id,
                                      "author_id" => mr.author_id,
                                      "raw_refs" => ["gitlab:#{mr.mr_id}"] })
          else
            @result.findings << {
              "status" => "violated",
              "at" => mr.merged_at.iso8601,
              "resource" => ref,
              "evidence" => {
                "repo" => mr.repo, "mr_id" => mr.mr_id,
                "author_id" => mr.author_id,
                "reason" => "合并到受保护分支但无合并前的非作者批准",
                "exception_tickets_on_record" => mr.exception_ticket_ids,
                "raw_refs" => ["gitlab:#{mr.mr_id}"]
              }
            }
          end
        end
      end

      # ---- PM-01：服务器补丁按 SLA 安装 --------------------------------------
      # 违规区间 = [SLA 截止, 实际安装)；未安装延伸到周期终点。
      def evaluate_patch_sla(ctx)
        ctx.patches.each do |p|
          next if p.deadline_at >= ctx.period.end_time # 周期内尚未逾期，本周期不适用

          violation_start = [p.deadline_at, ctx.period.start_time].max
          violation_end = [(p.installed_at || ctx.period.end_time), ctx.period.end_time].min
          next if violation_start >= violation_end

          ref = "patch:#{p.server_id}:#{p.patch_id}"
          vrange = ISMS::TimeRange.new(violation_start, violation_end)
          apply_with_exceptions(ctx, vrange, resource_ref: ref,
                                evidence_base: {
                                  "server_id" => p.server_id,
                                  "hostname" => p.hostname,
                                  "patch_id" => p.patch_id,
                                  "severity" => p.severity,
                                  "deadline_at" => p.deadline_at.iso8601,
                                  "installed_at" => p.installed_at&.iso8601,
                                  "raw_refs" => ["cloudpatch:#{p.server_id}:#{p.patch_id}"]
                                })
        end
      end

      # ---- GOV-01：跨系统身份可解析率 ---------------------------------------
      # 无法映射的账号意味着离职控制可能漏人——这本身是一项治理控制。
      def evaluate_identity_mapping(ctx)
        ctx.identity_pending.each do |item|
          @result.findings << {
            "status" => "violated",
            "at" => ctx.period.start_time.iso8601,
            "resource" => "account:#{item[:source_system]}:#{item[:external_login]}",
            "evidence" => {
              "source_system" => item[:source_system],
              "external_login" => item[:external_login],
              "identity_hint" => item[:identity_hint],
              "reason" => item[:reason],
              "action_required" => "人工确认身份映射后重算本周期结果"
            }
          }
        end
      end

      # ---- 共享：区间 + 例外的时间轴切分 ------------------------------------
      def apply_with_exceptions(ctx, violation_range, resource_ref:, evidence_base:)
        # 只保留合法、且"控制 + 资源"两个维度精确匹配的例外
        matched = ctx.exceptions.select do |ex|
          ex.valid? && ex.applies_to?(control_id: @rule["id"], resource_ref: resource_ref)
        end

        # 每条例外与违规区间求交集，保留 (例外, 交集) 的配对，避免按区间反查的歧义
        overlaps = matched.map { |ex| [ex, ex.overlap_with(violation_range)] }
                          .reject { |_, r| r.nil? }
        exempt_ranges = overlaps.map(&:last)

        overlaps.each do |ex, r|
          @result.exceptions_applied << ex.exception_id
          @result.segments << segment("exempted", r,
                                      evidence_base.merge("exception_id" => ex.exception_id,
                                                          "reason" => ex.reason,
                                                          "compensating_controls" => ex.compensating_controls))
        end

        violation_range.subtract(exempt_ranges).each do |r|
          @result.segments << segment("violated", r, evidence_base)
        end
      end

      def matching_exception(ctx, control_id:, resource_ref:, at:)
        ctx.exceptions.find do |ex|
          ex.valid? && ex.applies_to?(control_id: control_id, resource_ref: resource_ref) &&
            ex.active_at?(at)
        end
      end

      def record_exempted_finding(at, ref, ex, evidence)
        @result.exceptions_applied << ex.exception_id
        @result.findings << {
          "status" => "exempted",
          "at" => at.iso8601,
          "resource" => ref,
          "evidence" => evidence.merge("exception_id" => ex.exception_id,
                                       "reason" => ex.reason,
                                       "compensating_controls" => ex.compensating_controls)
        }
      end

      def segment(status, range, evidence)
        { "status" => status, "range" => range.to_h, "evidence" => evidence }
      end

      # 数据缺口以独立 gap 段挂到时间轴上（难点3）。
      # 只计入本控制实际依赖的数据源——补丁系统采集失败不影响代码评审控制。
      def attach_coverage_gaps(ctx)
        in_scope = Array(@rule["data_sources"])
        ctx.connectors.select { |c| in_scope.include?(c.source) }.each do |connector|
          connector.coverage_gaps(ctx.period).each do |gap|
            @result.coverage_gaps << gap
            @result.segments << {
              "status" => "gap",
              "range" => gap["range"],
              "evidence" => { "source" => gap["source"], "reason" => gap["reason"] }
            }
          end
        end
      end
    end
  end
end

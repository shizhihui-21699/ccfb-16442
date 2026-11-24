# frozen_string_literal: true

$LOAD_PATH.unshift(File.expand_path("../lib", __dir__))
require "minitest/autorun"
require "yaml"
require "isms"

# 端到端回归：直接使用 demo_data，断言四个控制在审核周期上的完整结论。
# 这里覆盖了开发过程中实际抓到的每一类引擎缺陷，防止它们复发。
class EngineIntegrationTest < Minitest::Test
  ROOT = File.expand_path("..", __dir__)
  PERIOD = ISMS::TimeRange.new(Time.utc(2026, 7, 1), Time.utc(2026, 10, 1))

  def setup
    @rules = ISMS::Engine::RuleLoader.load_dir(File.join(ROOT, "config/controls"))

    exceptions = YAML.safe_load(File.read(File.join(ROOT, "config/exceptions.yml")))["exceptions"]
                 .map { |a| ISMS::Domain::ExceptionWindow.new(a.map { |k, v| [k.to_sym, v] }.to_h) }
    @valid_exceptions = exceptions.select(&:valid?)
    @invalid_exceptions = exceptions.reject(&:valid?)

    id_cfg = YAML.safe_load(File.read(File.join(ROOT, "config/identity_mappings.yml")))
    @mapper = ISMS::Domain::IdentityMapper.new(
      mappings: id_cfg["mappings"].map { |m| m.map { |k, v| [k.to_sym, v] }.to_h },
      confidence_threshold: id_cfg["confidence_threshold"]
    )

    @hr = ISMS::Connectors::HRConnector.new(
      source: "hr", data_path: File.join(ROOT, "demo_data/hr_employees.json"),
      expected_interval_hours: 168)
    @aws = ISMS::Connectors::CloudConnector.new(
      source: "aws_iam", data_path: File.join(ROOT, "demo_data/aws_iam.json"),
      expected_interval_hours: 168)
    @gitlab = ISMS::Connectors::RepoConnector.new(
      source: "gitlab", data_path: File.join(ROOT, "demo_data/gitlab.json"),
      expected_interval_hours: 168)
    @patcher = ISMS::Connectors::PatchConnector.new(
      source: "cloudpatch", data_path: File.join(ROOT, "demo_data/cloud_patch.json"),
      expected_interval_hours: 336,
      severity_sla_hours: @rules["PM-01"]["params"]["severity_sla_hours"])
    @tickets = ISMS::Connectors::TicketConnector.new(
      source: "tickets", data_path: File.join(ROOT, "demo_data/tickets.json"),
      expected_interval_hours: 168)

    accounts = @aws.normalize + @gitlab.accounts
    @mapper.annotate!(accounts)

    @ctx = ISMS::Engine::Evaluator::Context.new(
      period: PERIOD, people: @hr.normalize, accounts: accounts,
      merge_requests: @gitlab.merge_requests, patches: @patcher.normalize,
      tickets: @tickets.normalize, exceptions: @valid_exceptions,
      connectors: [@hr, @aws, @gitlab, @patcher, @tickets],
      identity_pending: @mapper.pending_review)
  end

  def evaluate(id)
    ISMS::Engine::Evaluator.new(@rules[id]).run(@ctx)
  end

  def test_acc01_exemption_window_splits_violation_timeline
    result = evaluate("ACC-01")
    statuses = result.segments.map { |s| s["status"] }
    assert_includes statuses, "exempted"
    assert_includes statuses, "violated"
    assert_includes result.exceptions_applied, "EX-2026-001"

    wangwu = result.segments.select { |s| s.dig("evidence", "account") == "aws_iam:wangwu-key" }
    exempted = wangwu.find { |s| s["status"] == "exempted" }
    violated = wangwu.find { |s| s["status"] == "violated" }
    # 豁免窗口 8/21~9/5；窗口结束到 9/8 实际禁用之间仍是违规
    assert_equal "2026-08-21T09:00:00Z", exempted["range"]["start"]
    assert_equal "2026-09-05T00:00:00Z", exempted["range"]["end"]
    assert_equal "2026-09-05T00:00:00Z", violated["range"]["start"]
    assert_equal "2026-09-08T10:00:00Z", violated["range"]["end"]
  end

  def test_acc01_never_disabled_account_violates_for_whole_remaining_period
    result = evaluate("ACC-01")
    zhaoliu = result.segments.select do |s|
      s["status"] == "violated" && s.dig("evidence", "account") == "aws_iam:zhaoliu-key"
    end
    assert_equal 1, zhaoliu.size
    assert_equal "2026-10-01T00:00:00Z", zhaoliu.first["range"]["end"]
  end

  def test_acc01_unmapped_accounts_are_not_attributed_to_anyone
    result = evaluate("ACC-01")
    accounts = result.segments.map { |s| s.dig("evidence", "account") }.compact
    refute_includes accounts, "aws_iam:orphan-temp-key"
    refute_includes accounts, "gitlab:former_contractor"
  end

  def test_cr01_distinguishes_approved_self_approved_unreviewed_and_emergency
    result = evaluate("CR-01")
    by_mr = result.findings.each_with_object({}) { |f, h| h[f["resource"]] = f["status"] }
    assert_equal "effective", by_mr["mr:core-service!1001"]
    assert_equal "violated", by_mr["mr:core-service!1002"]
    assert_equal "violated", by_mr["mr:core-service!1050"] # 作者自己批准不算独立评审
    assert_equal "exempted", by_mr["mr:payments!1042"]      # 紧急变更工单豁免
    # 非保护分支的合并不在控制范围内
    refute by_mr.key?("mr:web-portal!1003")
  end

  def test_pm01_sla_uses_unified_deadline_and_applies_patch_exception
    result = evaluate("PM-01")
    trade = result.segments.select do |s|
      s.dig("evidence", "patch_id") == "KB-2026-3301"
    end.sort_by { |s| s["range"]["start"] }
    assert_equal %w[exempted violated], trade.map { |s| s["status"] }
    # high 级 SLA 15 天：8/20 发布 -> 9/4 截止；例外覆盖 9/4~9/12
    assert_equal "2026-09-04T00:00:00Z", trade.first["range"]["start"]
    assert_equal "2026-09-12T00:00:00Z", trade.first["range"]["end"]
    # 周期内未逾期的 medium 补丁（9/24 发布）不应产生发现
    refute result.segments.any? { |s| s.dig("evidence", "patch_id") == "KB-2026-4500" }
  end

  def test_gov01_reports_all_unresolved_identities
    result = evaluate("GOV-01")
    resources = result.findings.map { |f| f["resource"] }.sort
    assert_equal ["account:aws_iam:orphan-temp-key",
                  "account:gitlab:former_contractor",
                  "account:gitlab:lisi_backup"], resources
  end

  def test_coverage_gaps_attach_only_to_controls_using_that_source
    acc = evaluate("ACC-01")
    cr = evaluate("CR-01")
    assert(acc.coverage_gaps.all? { |g| %w[hr aws_iam gitlab].include?(g["source"]) })
    assert(cr.coverage_gaps.none? { |g| g["source"] == "cloudpatch" })
  end

  def test_invalid_self_approved_exception_is_rejected
    assert_equal 1, @invalid_exceptions.size
    assert_equal "EX-2026-BAD", @invalid_exceptions.first.exception_id
    # 非法例外不得进入引擎上下文，zhaoliu 的 gitlab 账号因此不能被豁免
    result = evaluate("ACC-01")
    refute_includes result.exceptions_applied, "EX-2026-BAD"
  end
end

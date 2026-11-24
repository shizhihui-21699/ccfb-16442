# frozen_string_literal: true

# 端到端演示：从四个系统的模拟数据出发，完成规范化、身份解析、
# 持续符合性评估，最终生成证据包。无需任何外部 gem。
$LOAD_PATH.unshift(File.expand_path("../lib", __dir__))
require "json"
require "yaml"
require "date"
require "fileutils"
require "isms"

ROOT = File.expand_path("..", __dir__)
PERIOD = ISMS::TimeRange.new(Time.utc(2026, 7, 1), Time.utc(2026, 10, 1))
PERIOD_LABEL = "2026Q3"
OUTPUT_DIR = File.join(ROOT, "output")

# 1. 加载规则与例外 ---------------------------------------------------------
rules = ISMS::Engine::RuleLoader.load_dir(File.join(ROOT, "config/controls"))
exception_config = YAML.safe_load(File.read(File.join(ROOT, "config/exceptions.yml")))
exceptions = exception_config["exceptions"].map do |attrs|
  ISMS::Domain::ExceptionWindow.new(attrs.map { |k, v| [k.to_sym, v] }.to_h)
end
invalid_exceptions = exceptions.reject(&:valid?)
valid_exceptions = exceptions.select(&:valid?)

identity_config = YAML.safe_load(File.read(File.join(ROOT, "config/identity_mappings.yml")))
mapper = ISMS::Domain::IdentityMapper.new(
  mappings: identity_config["mappings"].map { |m| m.map { |k, v| [k.to_sym, v] }.to_h },
  confidence_threshold: identity_config["confidence_threshold"]
)

# 2. 连接器采集与规范化 ------------------------------------------------------
hr = ISMS::Connectors::HRConnector.new(
  source: "hr", data_path: File.join(ROOT, "demo_data/hr_employees.json"),
  expected_interval_hours: 168
)
aws = ISMS::Connectors::CloudConnector.new(
  source: "aws_iam", data_path: File.join(ROOT, "demo_data/aws_iam.json"),
  expected_interval_hours: 168
)
gitlab = ISMS::Connectors::RepoConnector.new(
  source: "gitlab", data_path: File.join(ROOT, "demo_data/gitlab.json"),
  expected_interval_hours: 168
)
patch_sla = rules["PM-01"]["params"]["severity_sla_hours"]
                .map { |k, v| [k, v] }.to_h
patcher = ISMS::Connectors::PatchConnector.new(
  source: "cloudpatch", data_path: File.join(ROOT, "demo_data/cloud_patch.json"),
  expected_interval_hours: 336, severity_sla_hours: patch_sla
)
ticket_connector = ISMS::Connectors::TicketConnector.new(
  source: "tickets", data_path: File.join(ROOT, "demo_data/tickets.json"),
  expected_interval_hours: 168
)

connectors = [hr, aws, gitlab, patcher, ticket_connector]
raw_records = connectors.flat_map(&:raw_records)

people = hr.normalize
cloud_accounts = aws.normalize
gitlab_accounts = gitlab.accounts
merge_requests = gitlab.merge_requests
patches = patcher.normalize
tickets = ticket_connector.normalize

# 3. 身份解析（确定性映射，低置信度进人工裁决队列）---------------------------
all_accounts = cloud_accounts + gitlab_accounts
mapper.annotate!(all_accounts)

ctx = ISMS::Engine::Evaluator::Context.new(
  period: PERIOD,
  people: people,
  accounts: all_accounts,
  merge_requests: merge_requests,
  patches: patches,
  tickets: tickets,
  exceptions: valid_exceptions,
  connectors: connectors,
  identity_pending: mapper.pending_review
)

# 4. 逐项控制评估 ------------------------------------------------------------
results = rules.values.sort_by { |r| r["id"] }.map do |rule|
  ISMS::Engine::Evaluator.new(rule).run(ctx)
end

# 5. 输出与证据包 ------------------------------------------------------------
FileUtils.rm_rf(OUTPUT_DIR)
FileUtils.mkdir_p(OUTPUT_DIR)
results.each do |result|
  File.write(File.join(OUTPUT_DIR, "#{result.control_id}.json"),
             JSON.pretty_generate(result.to_h) + "\n")
end

pack_dir = ISMS::Evidence::Packager.new(output_dir: OUTPUT_DIR, period_label: PERIOD_LABEL)
             .build(results: results, raw_records: raw_records, rules: rules,
                    exceptions: exceptions, identity_pending: mapper.pending_review,
                    period: PERIOD)

# 6. 控制台摘要 --------------------------------------------------------------
puts "=" * 72
puts "ISMS 持续监测演示 — 审核周期 #{PERIOD_LABEL}（#{PERIOD.start_time.strftime('%F')} ~ #{PERIOD.end_time.strftime('%F')}）"
puts "=" * 72
results.each do |r|
  puts format("%-7s %-28s 结论=%-12s 违规段=%d 豁免段=%d 缺口=%d 点式发现=%d",
              r.control_id, r.control_name, r.status,
              r.segments.count { |s| s["status"] == "violated" },
              r.segments.count { |s| s["status"] == "exempted" },
              r.coverage_gaps.size, r.findings.size)
end
puts "-" * 72
puts "人工裁决队列（身份无法可靠映射）：#{mapper.pending_review.size} 项"
mapper.pending_review.each { |i| puts "  - #{i[:source_system]}:#{i[:external_login]} — #{i[:reason]}" }
puts "被拦截的非法例外：#{invalid_exceptions.size} 项"
invalid_exceptions.each { |e| e.validation_errors.each { |msg| puts "  - #{msg}" } }
puts "-" * 72
puts "证据包目录：#{pack_dir}"
puts "校验命令：(cd #{pack_dir} && shasum -a 256 -c sha256_manifest.txt)"

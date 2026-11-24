# 核心引擎保持零外部依赖（Ruby 标准库即可运行、可测试）。
# 以下 gem 仅在生产化部署时需要，离线环境可按需安装。
source "https://rubygems.org"

# Web 管理界面 / 后台任务（生产化层，核心域逻辑不依赖 Rails）
gem "rails", "~> 6.0"
gem "pg"                       # PostgreSQL：tstzrange + GiST 支撑双时态区间查询
gem "sidekiq"                  # 定时采集与重算任务
gem "rack", "~> 2.2"

group :development, :test do
  gem "minitest"               # Ruby 2.6 已内置，此处仅声明
  gem "rake"
end

#!/usr/bin/env bash
set -euo pipefail

cd /usr/src/redmine

echo "Waiting for database..."
until ruby -r pg -e "PG.connect(host: ENV.fetch('REDMINE_DB_POSTGRES'), port: ENV.fetch('REDMINE_DB_PORT', '5432'), dbname: ENV.fetch('REDMINE_DB_DATABASE'), user: ENV.fetch('REDMINE_DB_USERNAME'), password: ENV.fetch('REDMINE_DB_PASSWORD')).close"; do
  sleep 2
done

echo "Running db:migrate..."
bundle exec rake db:migrate RAILS_ENV=production

echo "Loading Redmine default data..."
bundle exec rake redmine:load_default_data RAILS_ENV=production REDMINE_LANG=ja

echo "Running redmine:plugins:migrate..."
bundle exec rake redmine:plugins:migrate RAILS_ENV=production

echo "Precompiling assets..."
bundle exec rake assets:precompile RAILS_ENV=production

echo "Seeding Easy Gantt test data..."
bundle exec rails runner -e production docker/redmine/seed_easy_gantt.rb

echo "Starting Redmine..."
exec rails server -b 0.0.0.0 -p 3000 -e production

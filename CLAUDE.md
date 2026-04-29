# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## 開発環境の起動と運用

このリポジトリは Redmine 6 用プラグイン `redmine_easy_gantt` の開発環境であり、Redmine 本体や Gemfile は同梱しない。Rails / Ruby は `redmine:6.0` イメージのものをそのまま利用する想定なので、ローカルに Ruby を入れる必要はない。

```sh
docker compose up         # 通常起動。DB 永続化、プラグインソースは bind mount
docker compose down       # 停止のみ
docker compose down -v    # postgres_data と redmine_files まで消して完全初期化
docker compose logs -f redmine   # Rails ログ
```

`docker compose up` の起動シーケンスは `docker/redmine/entrypoint.sh` が制御しており、毎回コンテナ内で次を実行する点に注意:

1. DB 待機 → `db:migrate` (production)
2. `redmine:load_default_data REDMINE_LANG=ja` (毎回実行されるが冪等)
3. `redmine:plugins:migrate`
4. `assets:precompile`
5. `rails runner docker/redmine/seed_easy_gantt.rb` でテストデータ投入
6. `rails server -e production`

そのため初回や `down -v` 直後の起動は数分かかる。プラグインのソース (`plugins/redmine_easy_gantt`) と entrypoint (`docker/redmine`) はホストから bind mount されているので、Ruby/ERB/JS/CSS の変更は通常コンテナ再起動 (`docker compose restart redmine`) で反映できるが、CSS/JS は production モードでプリコンパイル済みアセットを参照しているため、意図通り反映されない場合は `docker compose up` で再起動して assets:precompile を走らせ直すか、コンテナ内で `bundle exec rake assets:precompile RAILS_ENV=production` を再実行する。

ログイン情報:
- 管理者: `admin` / `admin`
- テストユーザー: `pm`, `dev1`, `dev2`, `reviewer` (全員 `password`)。プロジェクト `easy-gantt-test` のメンバーで、`Easy Gantt Manager` ロール (`view_easy_gantt`, `edit_easy_gantt` を持つ) が割り当てられている。

`seed_easy_gantt.rb` は次のプロジェクト階層を作る:

- ルート: `easy-gantt-test` / `Easy Gantt Test` (チケットは作らず、配下の集約ガント表示確認用)
- サブ 1: `easy-gantt-plan` / `計画フェーズ` (開始日 2026-05-01)
- サブ 2: `easy-gantt-dev` / `開発フェーズ` (開始日 2026-06-01)
- サブ 3: `easy-gantt-ops` / `運用フェーズ` (開始日 2026-07-01)

各サブプロジェクトには「親 1 + 子 9」を 10 グループ生成して 100 件ぴったり、合計 300 件のチケットを投入する。サブプロジェクトは `project.set_parent!(root_project)` で紐づけているのでネストセット (lft/rgt) も更新される。チケット数を変えたいときは `groups_per_subproject` / `children_per_group` を、開始日や名前を変えたいときは `subproject_definitions` を編集する。`easy_gantt` モジュールとトラッカー、`Easy Gantt Manager` ロールはルート + 全サブプロジェクトに対して同じものを有効化している。

## アーキテクチャ

このプラグインはサーバー側を極小に保ち、ガントチャートの描画・編集はすべてクライアント JS に寄せた構成になっている。

### Rails 側 (`plugins/redmine_easy_gantt`)

- `init.rb` で `project_module :easy_gantt` を定義し、`view_easy_gantt` / `edit_easy_gantt` の 2 権限とプロジェクトメニュー (標準ガント `gantt` の直後) を登録する。プロジェクトでこのモジュールを有効にしないとメニューに出ない。
- `config/routes.rb` のエンドポイントは 4 本だけ:
  - `GET /projects/:project_id/easy_gantt` — `index` (ERB 1 枚を返すだけ)
  - `GET /projects/:project_id/easy_gantt/issues` — JSON。プロジェクト + 子孫プロジェクトの可視チケットを presenter 形式で返す
  - `PATCH /easy_gantt/issues/:id` — `start_date` / `due_date` / `done_ratio` の部分更新
  - `PATCH /easy_gantt/issues/:id/parent` — 親付け替え専用
- `EasyGanttController` の重要な振る舞い:
  - `index`/`issues` は `find_project_by_project_id` + `authorize` で保護され、`edit_*` 系は `edit_easy_gantt` 権限を都度確認する。プロジェクトをまたいだチケット編集にも対応するため、`update_*` 側は `find_project_by_project_id` ではなくチケット側の project に対して権限チェックする (`authorize_issue_update`)。
  - `issue_params` で `permit` する属性は意図的に 3 つ (`start_date`/`due_date`/`done_ratio`) のみ。それ以外を編集したくなったら controller, JS の送信側、presenter の 3 か所を揃って更新する。
  - 日付は `Date.iso8601` でパースし、不正値は `nil` として扱う。`start_date > due_date` と `done_ratio` の範囲外は `422` で `success: false` の JSON を返す。
  - 親付け替えは循環防止のため `issue_ids_from_parent_to_root` で祖先列を辿って自身を含むかチェックする。サブタスク化や直系の祖先付け替えを変更するときはこのループを必ず再確認する。
- `EasyGanttIssuePresenter` がフロントへ渡す JSON 形を一元管理する。`editable` フラグは `User.current.allowed_to?(:edit_easy_gantt, issue.project)` で都度算出するので、フロント側の権限分岐はこの値だけを見ればよい。新しい属性をガント上に出すときはこの presenter に追加する。

### フロントエンド (`assets/javascripts/easy_gantt.js`, `assets/stylesheets/easy_gantt.css`)

- ビルドツールは無し。素の ES5 系 JS を `javascript_include_tag` でそのまま配信している。Babel/Webpack 等を導入する前に Redmine の `assets:precompile` 経路と相性を確認すること。
- `index.html.erb` が描画するのは `<div id="easy-gantt">` 1 つだけ。`data-issues-url` と `data-issue-update-url-template` (`__ISSUE_ID__` プレースホルダ) を読み取って fetch する設計なので、URL 構築ロジックを Rails 側に閉じ込めている。新しいエンドポイントを追加するときも同じ data 属性方式に合わせる。
- 全状態は IIFE 内のシングルトン `state` オブジェクトに集約 (`issues`, `issueMap`, `pendingSaves`, `pendingProgressSaves`, `leftPaneWidth`, `leftPaneCollapsed`, `flash` など)。`renderGantt()` は毎回フルレンダリングし、差分更新はしない。レンダリング負荷は seed の 500 件で確認しているので、これを大きく超える件数を扱う場合は仮想スクロール導入を検討する。
- DAY_WIDTH=24px, ROW_HEIGHT=32px, LEFT_PANE_WIDTH=320px の 3 定数がレイアウトの基準になっている。CSS とこの定数は連動しているため片方だけ変えると崩れる。
- 楽観的更新: バー操作・進捗変更時はまず `state.issues` を書き換えて再レンダリングし、`pendingSaves` / `pendingProgressSaves` 経由でデバウンス保存。サーバーが 422 を返したら `replaceIssue()` で巻き戻す方式なので、新しい編集操作を追加する際もこのパターンに従い、UI 状態とサーバー状態の整合をどこで取り戻すか明示する。
- 親子関係や日付ソートは `orderedIssues` (DFS) と `buildIssueMeta` で計算。Redmine 側のソート順 (`order(:start_date, :id)`) と JS 側のツリー再構成が二重にかかっている点に注意。

### ロケール

`config/locales/{ja,en}.yml` は今は最低限のキー (`label_easy_gantt`, 権限名, プレースホルダテキスト) しか持たない。新しい UI ラベルを追加するときは両ファイルへ同時に追加し、JS 側のハードコード文言 (例: 「チケット一覧を表示」) を増やす場合はロケール経由に寄せるかどうかを判断する。

## 作業上の注意点

- `down -v` はテストデータと添付ファイルを丸ごと消す。共有環境で安易に提案しないこと。
- 起動直後はデフォルトデータ + 500 チケットの seed が走るため、初回ログイン可能になるまで時間がかかる。CI 的に使うときは `REDMINE_NO_DB_MIGRATE=true` が docker-compose.yml で立っているのは Redmine イメージ標準の自動マイグレーションを抑止して、自前 entrypoint に処理を集約しているためで、勝手に外さない。
- テストフレームワークは未導入。プラグインの単体テスト/RSpec を追加する場合は Redmine 本体の test 構成 (`test/` 配下に `*_test.rb`、`bundle exec rake redmine:plugins:test NAME=redmine_easy_gantt`) との整合を取る前提で計画する。

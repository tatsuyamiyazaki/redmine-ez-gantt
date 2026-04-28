# redmine-easy-gantt
Redmineのチケットを、ガントチャート画面上で直感的に編集できるようにする。

## 開発環境

Redmine 6系で動作するプラグイン開発用の Docker Compose 環境です。

- Redmine: `redmine:6.0`
- DB: PostgreSQL 16
- URL: http://localhost:3000
- 初期ログイン: `admin` / `admin`
- プラグイン配置: `./plugins/redmine_easy_gantt`

## 起動手順

```sh
docker compose up
```

起動時に Redmine コンテナ内で DB 接続待機、`db:migrate`、Redmine default data load、`redmine:plugins:migrate`、assets precompile、テストデータ投入、Rails server 起動を実行します。

起動後、ブラウザで http://localhost:3000 にアクセスしてください。

初期ログインは `admin` / `admin` です。Easy Gantt の動作確認用ユーザーとして `pm`、`dev1`、`dev2`、`reviewer` が作成され、パスワードはいずれも `password` です。

## 初期化起動手順

DB データを初期化してテストデータを作り直す場合は、次の順に実行します。

```sh
docker compose down -v
docker compose up
```

## 停止手順

```sh
docker compose down
```

DB データや添付ファイル用ボリュームも削除して初期化する場合は、次のコマンドを実行します。

```sh
docker compose down -v
```

## ログ確認手順

Redmine のログを確認します。

```sh
docker compose logs -f redmine
```

PostgreSQL のログを確認します。

```sh
docker compose logs -f db
```

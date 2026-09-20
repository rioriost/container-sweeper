# Container Sweeper

Apple Container の清掃を日次・週次で設定する、日英対応の macOS アプリです。
SwiftUI の GUI から公式 `container` CLI を実行し、自動清掃はユーザー単位の
`launchd` LaunchAgent に登録します。アプリを閉じてもスケジュールは動作します。

A native, bilingual macOS settings app for scheduled Apple Container cleanup.
Create independent daily or weekly profiles, select cleanup actions, and register
them with per-user `launchd` agents. The GUI does not need to remain open.

## インストール / Install

Apple Silicon Mac・macOS 26 以降・[Homebrew](https://brew.sh/) が必要です。
[Apple Container](https://github.com/apple/container) の CLI も依存関係としてインストールされます。

```sh
brew install --cask rioriost/cask/container-sweeper
open -a "Container Sweeper"
```

清掃前に `container system start` で Container サービスを起動してください。
アプリで清掃内容を選び、自動実行を有効にして「保存して適用」を押すと登録できます。
アプリ更新後も「保存して適用」でヘルパーとスケジュールを更新してください。
本アプリは Container サービスを勝手に起動しません。

Requires an Apple Silicon Mac, macOS 26 or later, and Homebrew.
The Apple Container CLI is installed as a dependency. Before cleanup, start its
service with `container system start`. Open the app, select your cleanup actions,
enable scheduling, and choose **Save & Apply**. Repeat **Save & Apply** after
updating the app to refresh the helper and schedules. The app does not start
the Container service automatically.

## ソースからビルド / Build from source

ビルドには Apple Silicon Mac・macOS 14 以降・Swift 6 以降のツールチェーン（Xcode）・
Python 3.9 以降・`make` が必要です。実際の清掃には Apple Container の
OS・ハードウェア要件も満たす必要があります。CLI 1.4.1 の全操作に対応しています。

```sh
make test
make app
open "dist/Container Sweeper.app"
```

生成された `.app` は `/Applications` または `~/Applications` に移動できます。
ローカルビルドは ad-hoc 署名であり、公証済みの配布物ではありません。

Building requires an Apple Silicon Mac, macOS 14+, Swift 6 (Xcode), Python 3.9+,
and `make`. Running cleanup also requires a supported Apple Container environment.
CLI 1.4.1 supports all provided actions; older versions may not support `clean`.
Selected commands are checked before cleanup or schedule registration.
The build produces an ad-hoc signed `dist/Container Sweeper.app`, which you can
move to `/Applications` or `~/Applications`. This local build is not notarized.

## 設定例 / Example configuration

| プロファイル / Profile | 頻度 / Schedule | 操作 / Actions |
|---|---|---|
| 日次の軽い清掃 / Daily light cleanup | 毎日 03:00 / Daily at 03:00 | `clean` |
| 週次の清掃 / Weekly cleanup | 日曜 04:00 / Sunday at 04:00 | `clean` + `image prune` |
| 本格的な清掃 / Deep cleanup, opt-in | 任意の週次時刻 / A separate weekly time | `clean` + `prune` + `image prune --all` |

初期状態では自動実行も、破壊的な `prune`・`image prune --all` も無効です。
「自動清掃を有効にする」を選び、「保存して適用」で登録します。
イメージ清掃は「なし」「タグなし」「参照なし全体」の排他的な選択です。
日次・週次プロファイルの追加・削除、曜日・時刻・CLI パスの変更ができます。
表示言語はシステム設定に従います（日英対応）。アプリ独自の言語選択はありません。
以前保存した言語設定は無視します。
Apple Silicon では Homebrew の `/opt/homebrew/bin/container` を優先して検出します。

Automatic scheduling and destructive actions are **off by default**. Enable a
profile, then choose **Save & Apply**. Image cleanup modes are mutually exclusive.
Use **Run now** for a confirmed manual run using the current GUI settings,
including unsaved changes. Manual runs work even for disabled schedules.
The interface automatically follows the system language (English or Japanese).
There is no in-app language selector; previously saved language preferences are ignored.

### 同じ時刻の清掃を統合 / Merging overlapping schedules

同じ曜日・時刻に実行する有効なプロファイルは、1つの `launchd` ジョブにまとめます。
`clean` と `prune` はそれぞれ1回だけ実行し、イメージ清掃は
`image prune --all` があれば `image prune` を省略します。
片方だけに指定されている操作も残します。

例えば、日次03:00に `clean`、日曜03:00に `clean + image prune --all` を設定した場合、
月〜土は `clean` のみ、日曜は `clean + image prune --all` を1回実行します。
UI の「統合後の自動実行」で、曜日別の実行内容を確認できます。
手動実行は統合せず、選択したプロファイルだけを実行します。

Enabled profiles due on the same weekday and at the same wall-clock time share
one job. Their actions are unioned: `clean` and `prune` each run at most once, and
`image prune --all` supersedes `image prune`. Actions unique to either profile
are retained. Weekdays with identical profile membership share one job with
multiple calendar entries; no two jobs cover the same weekday/time.

For daily `clean` at 03:00 plus Sunday `clean + image prune --all` at 03:00,
Monday-Saturday run only `clean`; Sunday runs the combined actions once.
The GUI previews the merged weekday groups. Manual runs still execute only
the selected profile.

## 操作と安全性 / Behavior and safety

- `clean`: `container list --quiet` で起動中のコンテナを列挙し、各コンテナに実行します。
  ファイルシステムとマウント済み名前付きボリュームの未使用領域を回収します。
  コンテナが停止した等のエラーがあれば中断します。
- `prune`: **停止中の全コンテナと書き込み領域を削除**します。
- `image prune`: タグのない未使用イメージを削除します。
- `image prune --all`: コンテナから参照されていない全イメージを削除します。
  **再取得できないローカルビルドも対象**になり得ます。

Commands run in this order: **clean → stopped-container prune → image prune**.
Removing stopped containers first allows the subsequent image prune to consider
their formerly referenced images. Both destructive options require explicit
selection and confirmation before enabling automatic execution. Manual execution
also requires confirmation. There is **no age/last-used filter**, volume deletion,
forced deletion, builder-cache deletion, or automatic service startup.

実行時はコマンドの対応確認とサービスの起動確認を先に行い、失敗したら中断します。
途中まで完了した清掃は元に戻せません。CLI に対してシェル文字列を実行せず、
実行ファイルと引数配列を渡します。標準入力は閉じ、確認待ちで停止させません。
個々の清掃コマンドは10分でタイムアウトします。

The runner preflights all selected commands and checks service status before
modifying data. It stops on the first error; completed cleanup actions cannot be
rolled back. Commands use executable/argument arrays, not interpolated shell
scripts. Individual cleanup commands time out after 10 minutes. A shared file
lock prevents overlapping manual/scheduled runs and schedule updates. Same-slot
profiles have already been merged into one job. A collision between different
slots or a manual run fails visibly in its log; it is not queued or retried.

## launchd と保存場所 / Scheduling and storage

| 内容 / Item | 場所 / Location |
|---|---|
| 設定 / Configuration | `~/Library/Application Support/ContainerSweeper/configuration.json` |
| 実行ヘルパー / Headless helper | `~/Library/Application Support/ContainerSweeper/container-sweeper-runner` |
| LaunchAgents | `~/Library/LaunchAgents/dev.containersweeper.schedule.<HHmm>-<weekdays>.plist` |
| 実行ログ / Per-profile logs | `~/Library/Logs/ContainerSweeper/<UUID>.log` |
| グループログ / Group logs | `~/Library/Logs/ContainerSweeper/schedule-<HHmm>-<weekdays>.log` |
| 起動時エラー / Startup errors | `~/Library/Logs/ContainerSweeper/launchd.log` |

時刻はローカルタイムです。ログイン中のみ動作し、スリープ中に過ぎた予定は復帰時に
まとめて実行される場合があります。Mac の電源を入れたりスリープを解除したりはしません。
ログアウト・電源オフ時の予定を独自に追跡して実行する機能はありません。
同じ曜日・時刻の予定は統合済みですが、異なる予定がスリープ復帰時に重なった場合や、
前の時間帯の処理がまだ続いている場合は、後続がロックで拒否されることがあります。
エラー後は次回の予定まで自動再試行しません。

LaunchAgents run in the logged-in user's GUI domain, using local wall-clock time.
`StartCalendarInterval` may coalesce missed sleep-time events into a run on wake.
Jobs do not wake the Mac, run while logged out, or implement their own catch-up
after shutdown. Different calendar slots can still collide on wake or when an
earlier job runs long. Group membership is encoded in the job, not guessed from
the wake-up weekday, so a delayed weekly job retains its intended actions.
The `launchd status` button shows all saved groups for the selected profile and
their last exit status.

保存時にヘルパーを Application Support にコピーするため、GUI の移動・終了後も動きます。
アプリ更新後は開き直し、「保存して適用」でヘルパーも更新してください。登録失敗時は以前の
設定・ヘルパー・LaunchAgent を復元し、復元自体の失敗も表示します。
プロファイルは UUID で識別し、`launchd` ジョブは時刻と曜日集合で識別します。
保存時には、旧形式の `dev.containersweeper.job.<UUID>.plist` も解除・削除し、
統合後のジョブに置き換えます。手動で LaunchAgent を削除する必要はありません。

Saving installs the separately signed executable from `Contents/Helpers` as a
headless helper, rather than copying the app's bundle-bound main executable. Moving
or quitting the GUI does not break schedules. After an app update, reopen it and
**Save & Apply** again to update the helper. Saving also unloads/removes legacy
`dev.containersweeper.job.<UUID>.plist` jobs before installing grouped jobs.
Failed schedule registration rolls back configuration,
helper, and managed agents; rollback errors are explicitly reported. Unrelated
LaunchAgents are not modified.

Merged execution results are written to every participating profile's log and
to the group's log. Failures before profiles can be resolved (such as lock
contention) are recorded in the group log. Logs include timestamps, commands,
output, and explicit success/error markers.
They rotate after exceeding 1 MiB, retaining one previous file. Technical CLI and
launchd diagnostics are preserved in their original language. Logs may contain
container names and paths; review them before sharing.

## 停止・削除 / Disable and uninstall

1. 全プロファイルの自動実行を無効にして「保存して適用」します。
2. 必要なら `.app` を削除します。設定・ヘルパー・ログは上記の専用フォルダに残ります。

Disable every profile and **Save & Apply** to unload/remove all managed jobs.
Deleting the app alone does **not** stop scheduled cleanup. After disabling,
you can remove the app and its dedicated Application Support/log folders.

## 開発 / Development

```sh
make test
swift run ContainerSweeper
```

Tests use an isolated temporary home and a fake executor for all Container and
launchd operations: they do not clean real resources or register real schedules.
They cover schedule encoding, command combinations/order, compatibility failures,
fail-fast behavior, locking, persistence, grouped calendar coverage, action
deduplication, legacy-job migration, registration rollback, and log rotation.
Process-executor tests run only harmless system utilities.

Official command reference:
<https://github.com/apple/container/blob/1.4.1/docs/command-reference.md>

## ライセンス / License

本プロジェクトは MIT ライセンスで提供されています。詳細は [LICENSE](LICENSE) を参照してください。

This project is licensed under the MIT License. See [LICENSE](LICENSE) for details.

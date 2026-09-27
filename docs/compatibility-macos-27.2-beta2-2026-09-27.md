# macOS 27.2 beta 2 互換性検証 — 2026-09-27

## 結論と検証対象

MacBook Air の実機で、自動テスト、リリース構成のビルド、隔離GUIの起動、
Apple Container のコマンド対応と実サービスへの接続を確認した。
**確認範囲では互換性の問題は見つからなかった。**
実際の清掃や `launchd` による定時実行までの動作保証ではない。

検証対象のソースは `ec8c18ae81976b272911395915c20bf8b27c356b`。
検証開始時のワークツリーはクリーンで、検証のためのソース変更は行っていない。

| 項目 | 環境 |
| --- | --- |
| 実機 | MacBook Air、Apple Silicon（arm64） |
| OS | macOS 27.2、ビルド `26B5091g`（`sw_vers` で確認） |
| リリースチャネル | beta 2（ユーザー申告） |
| Swift | Apple Swift 6.4（`swiftlang-6.4.0.34.1`） |
| macOS SDK | 27.0 |
| Python | 3.14.7 |
| Container CLI／サーバー | 1.4.1 |

## 自動テストとビルド

| 確認項目 | 結果 |
| --- | --- |
| `make test`：コア・スケジュールの XCTest | 34件成功 |
| `make test`：エディターの Swift Testing | 5件成功 |
| `make test`：Python リリースワークフロー | 13件成功 |
| 自動テスト合計 | **52件成功、失敗0件** |
| `make app` | arm64 のリリース構成でビルド・パッケージ化成功 |
| アプリの署名 | ad-hoc 署名の `codesign --verify --deep --strict` 成功 |
| リソース | `--check-resources` で日英リソースの読み込み成功 |
| 同梱ヘルパー | `--help` と厳密な署名検証が成功 |
| アプリ外のヘルパー | 一時ディレクトリへコピー後も `--help` と厳密な署名検証が成功 |

生成物は `dist/Container Sweeper.app`。
ローカルの ad-hoc ビルドであり、公証済み配布物の検証ではない。
自動テストの Container 操作・LaunchAgent 操作は、隔離された一時ホームと
偽の実行器を使用する。実サービスへの接続確認は、次節の別の検証で行った。

## 実CLIとサービス接続

次の非破壊コマンドが成功した。ヘルプで `list --quiet` と
`image prune --all` のオプション対応も確認した。

```sh
container --version
container list --help
container clean --help
container prune --help
container image prune --help
container system status
container list --quiet
```

最初の確認時はサービスが停止しており、`system status` は
`apiserver is not running and not registered with launchd`、
一覧取得は XPC 接続エラーで終了した（いずれも終了コード1）。
ユーザーがサービスを起動した後の再確認では、両方とも終了コード0で成功した。
起動操作は検証処理からは行っていない。

サービスは CLI／サーバーともに 1.4.1、ホストは macOS 27.2／arm64 と報告した。
その時点のコンテナは全体・起動中ともに0件、イメージは2件だった。

さらに、一時的な検証ハーネスをリポジトリの `Configuration.swift` と
`Commands.swift` とともに Swift 6 モードでコンパイルし、
`/opt/homebrew/bin/container` に対して以下を確認した。

- `CleanupService.check`：操作を何も選択しない場合を除く、
  全11通りの有効な操作組み合わせで対応チェックが成功。
- `ProcessExecutor`：実サービスの状態取得とコンテナ一覧取得が成功。
  一覧出力はランナーと同じコンテナID検証条件も満たした。

これはコマンド対応と読み取り処理の検証であり、`CleanupService.perform` は呼び出していない。
`clean`、`prune`、`image prune` の実際の清掃操作は実行していない。
コンテナが0件だったため、空でない実一覧に対するID処理は今回の実サービス検証には含まれない。

## 隔離GUIの起動確認

既存のデバッグ専用プレビューを使用した。

```sh
python3 scripts/preview-ui.py
python3 scripts/preview-ui.py --english --light --compact
```

日本語／ダークと英語／ライト／コンパクトの各プレビューバイナリを、
`--preview-ui` と各状態の引数を指定して起動した。
状態は `default`、`merged`、`destructive`、`empty`、`load-error`、`busy` の6種類。
**2種類の表示条件 × 6状態、計12パターンすべてで起動確認が成功した。**

各起動では WindowServer に対象プロセスの可視ウィンドウが生成されたことと、
その後の1秒間の観測でプロセスが終了しなかったことを確認した。
確認後に検証用プロセスを終了し、残存していないことも確認した。
これは短時間の起動確認であり、スクリーンショットによる表示品質評価や操作監査ではない。

プレビューはメモリ内設定と独立したバンドル識別子を使用し、外部操作を禁止する。
実設定の読み込み、清掃、スケジュール登録は行っていない。

## 未検証範囲と副作用

- 実コンテナ・イメージの清掃、およびライブ環境での LaunchAgent 登録・定時実行。
- 長時間稼働、スリープ／復帰、詳細なGUI操作・レイアウト、アクセシビリティ。
- Developer ID 署名、公証、配布物の Gatekeeper 受け入れ。
- 他の macOS バージョンでの実行。

検証による実データの削除、既存の清掃設定・スケジュールの変更は行っていない。
初回のサービス停止による確認不能はユーザーによる起動後に解消したが、
上記の未検証範囲は残っている。

# Lore

Apple Silicon・macOS 14以降向けの、英語↔日本語の常駐翻訳アプリです。
文章を選択して⌘Cを400ms以内に2回押すと、カーソル付近に原文と訳文を表示します。
メニューバーから原文を手入力して使うこともできます。

AppKit / Objective-C++ / C++17で実装し、llama.cppを静的リンクしています。
推論はMetalを使ってアプリの1プロセス内で動作します。
Electron、Rust、Python、外部の推論サーバーは利用しません。

## ビルド・起動

Apple SiliconのMacに、AppleのCommand Line ToolsとCMakeを用意してください。

```sh
xcode-select --install
cmake --version
./scripts/build.sh
open build/Lore.app
```

初回のビルドでは、固定版llama.cpp b12307のソースを取得してSHA256を確認します。
取得物・中間ファイル・完成したアプリはすべてリポジトリ内の同じビルドディレクトリに置きます。
再実行は増分ビルドです。アプリの利用者にはCMakeや開発ツールは必要ありません。

継続して使う場合は、終了してからアプリをApplicationsへコピーし、その場所から開いて権限を設定してください。
ログイン起動も、アプリを置く場所を決めてから有効にしてください。

```sh
ditto build/Lore.app /Applications/Lore.app
open /Applications/Lore.app
```

既定では個人用のad-hoc署名を行います。自分の署名IDを使う場合は次のように指定できます。

```sh
./scripts/build.sh -DLORE_SIGNING_IDENTITY="Apple Development: Your Name (TEAMID)"
```

ビルド出力を消す場合は、アプリを終了してからリポジトリのビルドディレクトリを削除してください。
Application Supportに保存したモデルとmacOSの権限設定は別に保持されます。

## 初回セットアップ・使い方

1. 初回起動時に公式PLaMoモデル約573MBを取得し、サイズとSHA256を確認します。進捗は画面とメニューバーに表示します。失敗した場合はメニューの「モデルの準備を再試行」を使ってください。
2. メニューの「設定…」から入力監視の設定を開き、Loreを許可してください。その後「⌘C 2回で翻訳」を有効にします。許可がなくても手入力で翻訳できます。
3. 他のアプリで文章を選択し、⌘を押しながらCを2回押します。⌘を各回で押し直す操作にも対応します。
4. 必要に応じて原文を編集・方向を切り替えて再翻訳し、「訳文をコピー」を押します。画面内では⌘Returnで翻訳、Escで閉じます。

モデル取得後はオフラインで翻訳できます。常駐中はモデルと単一の推論コンテキストを保持し、要求がない間はワーカーを休眠させます。
原文・訳文の履歴ファイルやログは作りません。ログイン起動の初期値はオフです。

自動方向は、かな・漢字を含む文章を日本語→英語、それ以外を英語→日本語として扱います。
混在した文章や固有名詞は、画面から方向を指定できます。
対象は数文〜数段落です。入力上限はPFML3を含め4,096トークン、生成上限は4,096トークンです。
入力超過は案内を表示し、生成上限まで達した訳文は未完と表示します。

通常の⌘Cはそのまま機能します。長押し、別キーを挟む操作、前面アプリをまたぐ2回押しは翻訳を開始しません。
コピー結果を取得できない場合は、以前のクリップボードを翻訳しません。
コピー禁止の画面、画像だけの選択、Secure Keyboard Entry中は手入力を使ってください。
OSによってクリップボード読み取りの許可が表示される場合があります。拒否した場合も手入力は利用できます。

モデルの保存先：

```text
~/Library/Application Support/local.lore.Lore/plamo-3-translate-0.8b-Q4_K_M.gguf
```

## 検証

通常の製品ビルドにはテストやCLIは含めません。追加する場合も同じビルドディレクトリを使います。

```sh
./scripts/build.sh -DLORE_BUILD_TESTS=ON -DLORE_BUILD_SMOKE=ON
cmake --build build --target gesture_tests engine_smoke engine_profile --parallel 3
ctest --test-dir build --output-on-failure
./build/engine_smoke "$HOME/Library/Application Support/local.lore.Lore/plamo-3-translate-0.8b-Q4_K_M.gguf"
```

ジェスチャーのテストは400msの境界、タイムアウト、長押し、別キー、修飾キー、アプリ切替を確認します。
実モデルのテストは英日両方向、連続翻訳でのKVリセット、UTF-8、入力上限、逐次出力、生成中の新要求による取消を確認します。
任意の文章を1回翻訳することもできます。

```sh
./build/engine_smoke /path/to/model.gguf '会議は来週の月曜日に変更されました。'
```

常駐リソースの測定用に`engine_profile`も用意しています。同じモデルを保持したまま待機5秒のCPUと20回の翻訳を測定し、最初の訳文までの時間・完了時間・RSS・ピーク使用量を出力します。macOSではphysical footprintも出力します。これは推論部分の測定で、AppKit画面などを含むアプリ全体の測定は下記の実機確認で行います。

```sh
./build/engine_profile /path/to/model.gguf
```

Linuxではアプリを作らず、同じ推論コードをCPUで検証できます。

```sh
cmake -S . -B build -DLORE_BUILD_APP=OFF -DLORE_BUILD_TESTS=ON -DLORE_BUILD_SMOKE=ON
cmake --build build --parallel
ctest --test-dir build --output-on-failure
./build/engine_smoke /path/to/model.gguf
```

GitHub ActionsにはApple SiliconのmacOSでのビルド・署名確認・実モデルテストを用意しています。
これと別に、リリース前には実Macで以下を確認してください。

- Safari・Chrome・TextEdit・Preview・VS Codeでの選択翻訳、通常コピー、同一文の再翻訳、選択なし・画像コピー。
- 入力監視・クリップボード権限の拒否と取消、スリープ復帰、複数画面、フルスクリーン、表示時の元アプリのフォーカス維持。
- ダウンロード中断からの再試行、取得後のオフライン起動、翻訳中の閉じる・中止・終了。
- アクティビティモニタで待機60秒のCPU・実メモリ、翻訳中のピーク、繰り返し翻訳後の使用量。ファイルサイズと実メモリ量は別に記録する。
- InstrumentsのMetal System Traceで、待機中に継続的なGPU処理がないこと。Metalでの初回出力時間と翻訳完了時間も記録する。

## モデルとライセンス

Built with PLaMo. [PLaMo 3 Translate 0.8Bの公式GGUF Q4_K_M](https://huggingface.co/pfnet/plamo-3-translate-0.8b-GGUF)を変更せずに利用します。
モデルにはPLaMo Community Licenseが適用されます。個人利用を想定しており、他の用途の条件は公式モデルカードを確認してください。
推論ライブラリ[llama.cpp](https://github.com/ggml-org/llama.cpp/tree/b12307)はMIT Licenseです。
アプリのResourcesにはそのLICENSEと第三者ライセンスの案内を同梱します。

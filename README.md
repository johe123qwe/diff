difff《ﾃﾞｭﾌﾌ》
======================

致谢 / Acknowledgements
--------

本仓库 fork 自 **[meso-cacase/difff](https://github.com/meso-cacase/difff)**，
原作者是 **Yuki Naito**（[@meso_cacase](https://github.com/meso-cacase)）。

difff《ﾃﾞｭﾌﾌ》是一个非常好用的在线文本比较工具——它用 FIFO（命名管道）把文本交给
UNIX 的 diff 命令，比较过程中不把文档写入磁盘，并且能按字符（英文按单词）粒度
高亮出差异。本仓库只是在原项目的基础上做了一些界面上的改动，
**核心的比较逻辑完全来自原作者的工作**。
在此向原作者多年来的付出以及开源分享表示由衷的感谢！

This repository is a fork of **[meso-cacase/difff](https://github.com/meso-cacase/difff)**,
originally created by **Yuki Naito** ([@meso_cacase](https://github.com/meso-cacase)).
All credit for the original design and implementation belongs to the author —
this fork only adds a few interface tweaks on top of their work.
Thank you for building difff and sharing it as open source!

+ 原项目主页 / Original site: <https://difff.jp/>
+ 原仓库 / Upstream repository: <https://github.com/meso-cacase/difff>

本仓库沿用原项目的 modified BSD 许可证，版权声明见文末 License 一节。  
This fork is distributed under the same modified BSD license as the original;
see the License section at the bottom.


本仓库的改动 / Changes in this fork
--------

+ 界面简体中文化（`en/` 目录下的英文版仍保持英文）。
+ 比较结果顶部新增差异汇总条：显示「共有 N 处不同」或「没有不同」，
  并可用按钮或 `n` / `p` 键在各处差异之间逐处跳转。
+ 新增「只显示有差异的行」复选框，可把内容相同的行折叠起来，
  两列视图和一列视图里都能用，勾选状态在两个视图之间保持一致。
+ 新增浅色 / 深色主题切换按钮，默认浅色。
+ 新增「合并为一列」复选框，可把左右两列合并成一列连续文本，
  删除的内容标红并加删除线，新增的内容标绿；差异跳转、`n` / `p` 快捷键、
  「只显示有差异的行」、「黑白」打印配色在这个视图里同样可用。
+ 大文本优化：把逐字切分改成一次性匹配（原来的写法耗时与文本长度的平方成正比），
  文本较大时自动不再使用 `diff -d`，并把跨行的高亮改为逐行闭合
  （原来的正则在大段差异上会触发 Perl 的递归上限）。
  同时放宽了请求体积上限，并为单侧文本加了约 50 万字 / 词的上限，超出时给出提示。
  优化后处理时间和内存占用都与文本长度成正比：最坏情况（两边内容完全不同）
  每个字 / 词约需 1.1KB 内存，60 万字约 11 秒 / 670MB。
  上限在各脚本开头的 `$maxtoken` 一处定义，可按服务器内存自行调整，
  提示文字会跟着变；同时注意 `$maxrequest`（请求体上限，兼作内存兜底）。

除上面最后一条外，其余改动都只涉及页面展示。差异本身仍然由原项目的
`diff` 流程算出，比较过程也依然不把文档写入磁盘。

---

以下为原项目的 README。 / The original README follows.


**difff** is a simple, web-based online tool for comparing two text files.  
The software is open source, and freely available to all users.  
English version of difff: https://difff.jp/en/

ウェブベースのテキスト比較ツールです。2つのテキストの差分をハイライト表示します。  
本ソフトウェアはオープンソースであり、誰でも無償で自由に利用することができます。  
difff《ﾃﾞｭﾌﾌ》稼働中： https://difff.jp/

![スクリーンショット](http://data.dbcls.jp/~meso/img/difff6.png
"difff《ﾃﾞｭﾌﾌ》スクリーンショット")

作者が管理している
[difff《ﾃﾞｭﾌﾌ》のウェブサイト](https://difff.jp/)
はどなたでも無償で利用でき、入力テキストも一切サーバに残りませんが、
部外秘の文書をどうしても社内のサーバで ﾃﾞｭﾌﾌ したいというような要望が
多かったため、ソースを公開することにしました。どうぞご利用ください。

difff《ﾃﾞｭﾌﾌ》は差分検出にUNIXのdiffコマンドを利用しています。
diffコマンドは2つのファイルの差分を行単位で検出するプログラムです。
しかし、比較する文書をいったんファイルに書き出すのは秘匿性の点から
好ましくないので、difff《ﾃﾞｭﾌﾌ》ではファイルを書き出すのではなく
FIFO（名前付きパイプ）を作成してdiffコマンドに文書を渡しています。


動作環境
------

+ PerlのCGIが動作すること
+ UNIXのdiffコマンドが実行可能であること
+ FIFOを作成可能な、apacheからの書き込み権限のあるディレクトリがあること  
  ※ diffコマンドで文書を比較する際にFIFO（名前付きパイプ）を作成します。


インストール
------

difff《ﾃﾞｭﾌﾌ》は単一のCGIスクリプト（difff.pl）です。
本ファイルをウェブ公開用のディレクトリに置き、index.cgi にリンクします。
もしくは、difff.pl を index.cgi に名前変更して置いてもかまいません。
スクリプトには、apacheから読み出し・実行できる権限を与えてください。

また、スクリプトの下記の部分を環境にあわせて書き換えてください。

```perl
#!/usr/bin/perl
```

↑ Perlのパスを調べて記載してください。

```perl
# 保存したHTMLファイルから作業を再開できるよう、FORMの送り先に完全URLを指定
my $url = 'https://difff.jp/' ;
# 保存したHTMLファイルから作業を再開できなくてもよい場合は相対パスを指定
# my $url = './' ;
```

↑ CGIの設置先を完全URLで記載してください（index.cgi は記入不要）。
FORMタグの `action=` にこの値が入り、保存したHTMLファイルからでも
文書をPOSTできるようになります。その必要がない場合は上記のかわりに、

```perl
# 保存したHTMLファイルから作業を再開できるよう、FORMの送り先に完全URLを指定
# my $url = 'https://difff.jp/' ;
# 保存したHTMLファイルから作業を再開できなくてもよい場合は相対パスを指定
my $url = './' ;
```

のように設定してください。

```perl
my $diffcmd = '/usr/bin/diff' ;  # diffコマンドのパスを指定する
```

↑ diffコマンドのパスを調べて記載してください。

```perl
my $fifodir = '/tmp' ;           # FIFOを作成するディレクトリを指定する
```

↑ FIFOを作成可能な、apacheからの書き込み権限のあるディレクトリを指定。

以上で difff《ﾃﾞｭﾌﾌ》をウェブブラウザから利用できるようになります。

動かない場合、コマンドラインから下記を実行すると動作確認ができます。

```bash
% export QUERY_STRING="sequenceA=hogehoge&sequenceB=hagehage"
% ./index.cgi
```

出力の1行目が `Content-type: text/html; charset=utf-8`
となっており、2行目が空白行、3行目以降にHTMLが出力されれば成功です。
3行目以降のHTMLをファイルに書き出し、ブラウザで開いて内容を確認してください。

エラーが出る場合は、エラーメッセージを参照し対処してください。

また difff《ﾃﾞｭﾌﾌ》は比較の結果をサーバに保存し、公開用のURLを発行
することができます。結果の保存場所である data/ ディレクトリには、
apacheから読み書き・実行できる権限を与えてください。なお、公開版の
https://difff.jp/ では、保存期間を過ぎると結果が削除されます。
（結果を公開する機能が必要ない場合は6.0を利用してください）


更新履歴
--------

### 2017-08-07 ###

+ HTTPSによる暗号化通信に対応。

### 2015-06-17 ###

+ ﾃﾞｭﾌﾌの結果を公開する機能を追加。

### 2013-03-21 ###

+ 文字数カウンタを改良し、空白文字・改行を除いた文字数も表示。
+ 単語数もカウントするよう改良。

### 2013-03-12 ###

+ トップページの入力フォームのすぐ下に結果が表示されるように変更。  
  入力した文書と比較結果とをまとめて1つのHTMLファイルに保存できます。  
  また保存したHTMLを開いて作業を再開することも可能です。
+ 文字数をカウントする機能を追加。
+ ハイライトの色を、見やすいけれど疲れない色に変更。  
  ver.5と同じ緑色や、印刷に便利な白黒に切り替えることもできます。
+ 日本語の処理をPerl5.6/EUC-JPからPerl5.8/UTF-8に変更。

### 2013-01-11 ###

+ 英語版を公開。

### 2012-10-22 ###

+ difff《ﾃﾞｭﾌﾌ》ver.5のソースをGitHubで公開。


License
--------

Copyright &copy; 2004-2026 Yuki Naito
 ([@meso_cacase](https://twitter.com/meso_cacase))  
This software is distributed under
[modified BSD license](https://www.opensource.org/licenses/bsd-license.php).

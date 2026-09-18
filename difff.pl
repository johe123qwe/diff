#!/usr/bin/perl

# テキスト比較ツール difff《ﾃﾞｭﾌﾌ》： 2つのテキストの差分をハイライト表示するCGI
#
# 比較するテキストとして、HTTPリクエストから sequenceA および sequenceB を取得し、
# diffコマンドを用いて文字ごと（英単語は単語ごと）に比較し差分をハイライト表示する
#
# 2012-10-22 Yuki Naito (@meso_cacase)
# 2013-03-07 Yuki Naito (@meso_cacase) 日本語処理をPerl5.8/UTF-8に変更
# 2013-03-12 Yuki Naito (@meso_cacase) ver.6 トップページを本CGIと統合
# 2015-06-17 Yuki Naito (@meso_cacase) ver.6.1 結果を公開する機能を追加

use warnings ;
use strict ;
use utf8 ;
use POSIX ;

# 保存したHTMLファイルから作業を再開できるよう、FORMの送り先に完全URLを指定
my $url = 'https://diff.1010822.xyz/' ;
# 保存したHTMLファイルから作業を再開できなくてもよい場合は相対パスを指定
# my $url = './' ;

my $diffcmd = '/usr/bin/diff' ;  # diffコマンドのパスを指定
my $fifodir = '/tmp' ;           # FIFOを作成するディレクトリを指定

# 大きなテキストへの対応
# 処理時間もメモリもトークン数にほぼ比例する。両側がまったく違うテキストという
# 最悪ケースで、1トークンあたり約1.1KBのメモリと約18マイクロ秒を見込む
# （100万トークンで約19秒／約1.1GB）。サーバの空きメモリに合わせて調整する
my $maxtoken = 1000000 ;         # 片側あたりの最大トークン数
# トークン数が文字数を超えることはないので、split_text を通す前に文字数で足切り
# する。切り分けてから判定すると、拒否するだけでGB単位のメモリを使ってしまう。
# 英単語はまとめて1トークンになるため、トークン上限の4倍を目安にする
my $maxchar = $maxtoken * 4 ;    # 片側あたりの最大文字数
# UTF-8の日本語・中国語はURLエンコードで1文字9バイトになる。
# 100万文字なら片側9MB、両側で18MB
my $maxrequest = 30000000 ;      # 受け取るリクエストの最大バイト数
my $minimallimit = 30000 ;       # これを超えるトークン数では diff -d を使わない

binmode STDOUT, ':utf8' ;        # 標準出力をUTF-8エンコード
binmode STDERR, ':utf8' ;        # 標準エラー出力をUTF-8エンコード

# ▼ HTTPリクエストからクエリを取得し整形してFIFOに送る
my %query = get_query_parameters() ;

my $sequenceA = $query{'sequenceA'} // '' ;
utf8::decode($sequenceA) ;  # utf8フラグを有効にする

my $sequenceB = $query{'sequenceB'} // '' ;
utf8::decode($sequenceB) ;  # utf8フラグを有効にする

# 「忽略空行」の指定
my $ignoreblank = $query{'ignoreblank'} ? 1 : 0 ;

# 「忽略大小写」の指定
my $ignorecase = $query{'ignorecase'} ? 1 : 0 ;

# 「忽略行首尾空白」の指定
my $trimspace = $query{'trimspace'} ? 1 : 0 ;

# 両方とも空欄のときはトップページを表示
$sequenceA eq '' and $sequenceB eq '' and print_html() ;

# まず文字数で足切りする。length() は安いので、
# 巨大な入力を切り分ける前に追い返せる
(length($sequenceA) > $maxchar or length($sequenceB) > $maxchar) and
	print_html("ERROR : 文本太长，无法比较（每侧最多约 $maxtoken 个字 / 词）。请缩短后再试。") ;

# 比較には空行・行頭行末の空白を除いた写しを使い、
# フォームには入力されたままのテキストを残す
my $compareA = $sequenceA ;
my $compareB = $sequenceB ;
if ($trimspace){    # 先に行頭・行末の空白を落とし、
	$compareA = trim_line($compareA) ;
	$compareB = trim_line($compareB) ;
}
if ($ignoreblank){  # そのあと空行を落とす
	$compareA = strip_blank($compareA) ;
	$compareB = strip_blank($compareB) ;
}

my @a_split = split_text( escape_char($compareA) ) ;
my @b_split = split_text( escape_char($compareB) ) ;

# トークン数が多すぎる場合はここで打ち切る。
# FIFOを作る前に判定しないと、書き込み側の子プロセスが残ってしまう
(@a_split > $maxtoken or @b_split > $maxtoken) and
	print_html("ERROR : 文本太长，无法比较（每侧最多约 $maxtoken 个字 / 词）。请缩短后再试。") ;

my $fifopath_a = "$fifodir/difff.$$.A" ;  # $$はプロセスID
my $a_split = join("\n", @a_split) . "\n" ;
fifo_send($a_split, $fifopath_a) ;

my $fifopath_b = "$fifodir/difff.$$.B" ;  # $$はプロセスID
my $b_split = join("\n", @b_split) . "\n" ;
fifo_send($b_split, $fifopath_b) ;
# ▲ HTTPリクエストからクエリを取得し整形してFIFOに送る

# ▼ diffコマンドの実行
(-e $diffcmd) or print_html("ERROR : $diffcmd : not found") ;
(-x $diffcmd) or print_html("ERROR : $diffcmd : not executable") ;
# diff -d は最小の差分を探すため、大きな入力では極端に遅くなる。
# トークン数が多いときは -d を外し、現実的な時間で結果を返す
my @diffout = do {
	my $n = (@a_split > @b_split) ? scalar @a_split : scalar @b_split ;
	my $opt = ($n > $minimallimit) ? '' : '-d' ;
	# 「忽略大小写」: 1トークンが1行になっているので diff -i をそのまま使える
	$ignorecase and $opt .= ' -i' ;
	`$diffcmd $opt $fifopath_a $fifopath_b` ;
} ;
my @diffsummary = grep /(^[^<>-]|<\$>)/, @diffout ;
# ▲ diffコマンドの実行

# ▼ 1列表示用の差分ストリームを生成
# @a_split / @b_split にタグを埋め込む前に実行する必要がある
my @merged ;       # [$type, $num, $text]  $type: '=' 共通 / '-' 削除 / '+' 追加
my $m_pos   = 0 ;  # @a_split のうち共通部分として取り込み済みの位置
my $m_count = 0 ;  # 差分の箇所数（$diffcount と同じ順序で採番）

foreach (@diffsummary){
	if ($_ =~ /^((\d+),)?(\d+)c(\d+)(,(\d+))?$/){       # 置換している場合
		my $ae = $3 || 0 ; my $as = $2 || $ae ;
		my $bs = $4 || 0 ; my $be = $6 || $bs ;
		$m_count ++ ;
		merged_equal($as - 1) ;
		merged_diff('-', $m_count, \@a_split, $as - 1, $ae - 1) ;
		merged_diff('+', $m_count, \@b_split, $bs - 1, $be - 1) ;
		$m_pos = $ae ;
	} elsif ($_ =~ /^((\d+),)?(\d+)d(\d+)(,(\d+))?$/){  # 欠失している場合
		my $ae = $3 || 0 ; my $as = $2 || $ae ;
		$m_count ++ ;
		merged_equal($as - 1) ;
		merged_diff('-', $m_count, \@a_split, $as - 1, $ae - 1) ;
		$m_pos = $ae ;
	} elsif ($_ =~ /^((\d+),)?(\d+)a(\d+)(,(\d+))?$/){  # 挿入している場合
		my $ae = $3 || 0 ;
		my $bs = $4 || 0 ; my $be = $6 || $bs ;
		$m_count ++ ;
		merged_equal($ae) ;
		merged_diff('+', $m_count, \@b_split, $bs - 1, $be - 1) ;
		$m_pos = $ae ;
	}
}
merged_equal(scalar @a_split) ;

my $merged_text = '' ;
my %merged_seen ;
foreach my $seg (@merged){
	my ($type, $num, $text) = @$seg ;
	if ($type eq '='){
		$merged_text .= $text ;
		next ;
	}
	my $mark = $merged_seen{$num} ++ ? '' : "<span class=dm id=M$num></span>" ;
	$merged_text .= ($type eq '-') ?
		"$mark<del>$text</del>" : "$mark<ins>$text</ins>" ;
}

# 「只显示有差异的行」を1列表示でも使えるよう、1行ずつ<span>に入れる。
# 行をまたぐ<del>/<ins>は行ごとに閉じて開き直す
my @merged_line = split /(?<=<\$>)/, $merged_text ;
balance_tag(\@merged_line, 'del') ;
balance_tag(\@merged_line, 'ins') ;

my $merged_html = '' ;
foreach my $line (@merged_line){
	$line =~ s/<\$>/\n/g ;  # <$> を本来の改行に戻す（表示は white-space:pre-wrap）
	$merged_html .= "<span class=ml>$line</span>" ;
}
# ▲ 1列表示用の差分ストリームを生成

# ▼ 差分の検出とHTMLタグの埋め込み
my ($a_start, $a_end, $b_start, $b_end) = (0, 0, 0, 0) ;
my $diffcount = 0 ;  # 差分の箇所数
foreach (@diffsummary){  # 異なる部分をハイライト表示
	if ($_ =~ /^((\d+),)?(\d+)c(\d+)(,(\d+))?$/){       # 置換している場合
		$a_end   = $3 || 0 ;
		$a_start = $2 || $a_end ;
		$b_start = $4 || 0 ;
		$b_end   = $6 || $b_start ;
		$diffcount ++ ;
		$a_split[$a_start - 1] = "<span class=dm id=A$diffcount></span><em>" . ($a_split[$a_start - 1] // '') ;
		$a_split[$a_end - 1]  .= '</em>' ;
		$b_split[$b_start - 1] = "<span class=dm id=B$diffcount></span><em>" . ($b_split[$b_start - 1] // '') ;
		$b_split[$b_end - 1]  .= '</em>' ;
	} elsif ($_ =~ /^((\d+),)?(\d+)d(\d+)(,(\d+))?$/){  # 欠失している場合
		$a_end   = $3 || 0 ;
		$a_start = $2 || $a_end ;
		$b_start = $4 || 0 ;
		$b_end   = $6 || $b_start ;
		$diffcount ++ ;
		$a_split[$a_start - 1] = "<span class=dm id=A$diffcount></span><em>" . ($a_split[$a_start - 1] // '') ;
		$a_split[$a_end - 1]  .= '</em>' ;
	} elsif ($_ =~ /^((\d+),)?(\d+)a(\d+)(,(\d+))?$/){  # 挿入している場合
		$a_end   = $3 || 0 ;
		$a_start = $2 || $a_end ;
		$b_start = $4 || 0 ;
		$b_end   = $6 || $b_start ;
		$diffcount ++ ;
		$b_split[$b_start - 1] = "<span class=dm id=B$diffcount></span><em>" . ($b_split[$b_start - 1] // '') ;
		$b_split[$b_end - 1]  .= '</em>' ;
	} elsif ($_ =~ /> <\$>/){  # 改行の数をあわせる処理
		# 桁あわせで挿入する空行には <P> の目印をつける。行番号を振るときに
		# 本文の行と区別するため（<,> は実体参照になっているので入力とは衝突しない）
		my $i = ($a_start > 1) ? $a_start - 2 : 0 ;
		while ($i < @a_split and not $a_split[$i] =~ s/<\$>/<\$><P><\$>/){ $i ++ }
	} elsif ($_ =~ /< <\$>/){  # 改行の数をあわせる処理
		my $i = ($b_start > 1) ? $b_start - 2 : 0 ;
		while ($i < @b_split and not $b_split[$i] =~ s/<\$>/<\$><P><\$>/){ $i ++ }
	}
}
# ▲ 差分の検出とHTMLタグの埋め込み

# ▼ 比較結果のブロックを生成してHTMLを出力
my $a_final = join '', @a_split ;
my $b_final = join '', @b_split ;

my @a_final = split /<\$>/, $a_final ;
my @b_final = split /<\$>/, $b_final ;

# 変更箇所が<td>をまたぐ場合の処理、行ごとに<em>を閉じ直す
# （正規表現の繰り返しで処理すると、大きな差分で再帰の上限に達するため）
balance_tag(\@a_final, 'em') ;
balance_tag(\@b_final, 'em') ;

my $par = (@a_final > @b_final) ? @a_final : @b_final ;

# 行番号は桁あわせで挿入した空行（<P>）を飛ばして振る
my $a_lineno = 0 ;
my $b_lineno = 0 ;

my $table = '' ;
foreach (0..$par-1){
	defined $a_final[$_] or $a_final[$_] = '' ;
	defined $b_final[$_] or $b_final[$_] = '' ;
	$a_final[$_] =~ s{(\ +</em>)}{escape_space($1)}ge ;
	$b_final[$_] =~ s{(\ +</em>)}{escape_space($1)}ge ;
	# s///g は目印を消しつつ、あったかどうかも返す
	my $a_no = ($a_final[$_] =~ s/<P>//g) ? '' : ++ $a_lineno ;
	my $b_no = ($b_final[$_] =~ s/<P>//g) ? '' : ++ $b_lineno ;
	$table .=
"<tr>
	<td class=ln>$a_no</td><td>$a_final[$_]</td>
	<td class=ln>$b_no</td><td>$b_final[$_]</td>
</tr>
" ;
}

#- ▽ 文字数をカウントしてtableに付加
my ($count1_A, $count2_A, $count3_A, $wcount_A) = count_char($compareA) ;
my ($count1_B, $count2_B, $count3_B, $wcount_B) = count_char($compareB) ;

my $counts = <<"--EOS--" ;
<table id=charcount cellspacing=0>
<colgroup><col class=lncol><col><col class=lncol><col></colgroup>
<tr>
	<td class=ln></td><td><font color=gray>
		字符数: $count1_A<br>
		空格数: @{[$count2_A - $count1_A]} 含空格字符数: $count2_A<br>
		换行数: @{[$count3_A - $count2_A]} 含换行字符数: $count3_A<br>
		词数: $wcount_A
	</font></td>
	<td class=ln></td><td><font color=gray>
		字符数: $count1_B<br>
		空格数: @{[$count2_B - $count1_B]} 含空格字符数: $count2_B<br>
		换行数: @{[$count3_B - $count2_B]} 含换行字符数: $count3_B<br>
		词数: $wcount_B
	</font></td>
</tr>
</table>
--EOS--
#- △ 文字数をカウントしてtableに付加

#- ▽ 差分の総数と移動ボタンを生成
my $navbar = $diffcount ?
"<div id=diffnav>
<b>共有 $diffcount 处不同</b>&emsp;
<input type=button value='&#9664; 上一处' onclick='gotoDiff(-1)'>
<span id=diffpos>- / $diffcount</span>
<input type=button value='下一处 &#9654;' onclick='gotoDiff(1)'>
&emsp;<input type=checkbox id=onlydiff onclick='toggleOnlyDiff(this)'><!--
--><label for=onlydiff>只显示有差异的行</label>
&emsp;<input type=checkbox id=mergeview onclick='toggleMerge(this)'><!--
--><label for=mergeview>合并为一列</label>
&emsp;<input type=checkbox id=showln checked onclick='toggleLineNo(this)'><!--
--><label for=showln>显示行号</label>
<font color=gray size=1>&emsp;也可以按 n / p 键跳转</font>
</div>
" :
"<div id=diffnav class=same>
<b>没有不同（两边内容完全一致）</b>
&emsp;<input type=checkbox id=showln checked onclick='toggleLineNo(this)'><!--
--><label for=showln>显示行号</label>
</div>
" ;
#- △ 差分の総数と移動ボタンを生成

my $merged_block = $diffcount ?
"<div id=merged style='display:none'><div id=mergedhint><font color=gray size=1>红色为删除，绿色为新增</font></div><div id=mergedtext>$merged_html</div></div>
" : '' ;

my $message = <<"--EOS--" ;
<div id=result>
$navbar<table id=difftable cellspacing=0>
<colgroup><col class=lncol><col><col class=lncol><col></colgroup>
$table</table>
$merged_block$counts
<p>
	<input type=button id=hide value='仅显示结果 (便于打印)' onclick='hideForm()'> |
	<input type=radio name=color value=1 onclick='setColor1()' checked>
		<span class=blue >颜色1</span>
	<input type=radio name=color value=2 onclick='setColor2()'>
		<span class=green>颜色2</span>
	<input type=radio name=color value=3 onclick='setColor3()'>
		<span class=black>黑白</span>
</p>
</div>

<div id=save>
<hr><!-- ________________________________________ -->

<h4>公开分享此结果</h4>

<form method=POST id=save name=save action='${url}save.cgi'>
<p>将此结果保存到 difff 服务器，并生成一个公开的 URL。<br>
设置了删除密码的话，之后可以自己删掉。<br>
<b>公开期限为 3 天。</b>超过期限后会被自动删除。</p>

<table id=passwd>
<tr>
	<td class=n>删除密码：<input type=text name=passwd size=10 value=''></td>
	<td class=n>密码设置后无法再次查看，<br>请务必自行妥善保存。</td>
</tr>
</table>

<input type=submit onclick='return savehtml();' value='公开此结果'>

<p>只要不点击「公开此结果」，输入的内容就不会被保存到服务器。<br>
此功能处于试运行阶段，可能会在不预先通知的情况下停止提供。</p>
</form>
</div>
--EOS--

print_html($message) ;
# ▲ 比較結果のブロックを生成してHTMLを出力

exit ;

# ====================
sub get_query_parameters {  # CGIが受け取ったパラメータの処理
my $buffer = '' ;
if (defined $ENV{'REQUEST_METHOD'} and
	$ENV{'REQUEST_METHOD'} eq 'POST' and
	defined $ENV{'CONTENT_LENGTH'}
){
	eval 'read(STDIN, $buffer, $ENV{"CONTENT_LENGTH"})' or
	print_html('ERROR : get_query_parameters() : read failed') ;
} elsif (defined $ENV{'QUERY_STRING'}){
	$buffer = $ENV{'QUERY_STRING'} ;
}
length $buffer > $maxrequest and print_html('ERROR : input too large') ;
my %query ;
my @query = split /&/, $buffer ;
foreach (@query){
	my ($name, $value) = split /=/ ;
	if (defined $name and defined $value){
		$value =~ tr/+/ / ;
		$value =~ s/%([a-fA-F0-9][a-fA-F0-9])/pack('C', hex($1))/eg ;
		$name  =~ s/%([a-fA-F0-9][a-fA-F0-9])/pack('C', hex($1))/eg ;
		$query{$name} = $value ;
	}
}
return %query ;
} ;
# ====================
sub split_text {  # 比較する単位ごとに文字列を分割してリストに格納
my $text = join('', @_) // '' ;
$text =~ s/\n/<\$>/g ;  # もともとの改行を <$> に変換して処理
# 先頭から1トークンずつ s/// で削るとテキスト長の2乗に比例して遅くなるため、
# \G で順にマッチさせて一度に取り出す（大きなテキストへの対応）
# 大文字を含む単語も1トークンにする（[a-z]+ だと The が T と he に分かれ、
# 「忽略大小写」で大文字始まりの単語が一致しなくなる）
return $text =~ /\G([a-zA-Z]+|<\$>|&\#?\w+;|.)/gs ;
} ;
# ====================
sub strip_blank {  # 空行（空白だけの行を含む）を取り除く
my $text = $_[0] // '' ;
my $lf = ($text =~ /\n\z/) ? "\n" : '' ;  # 末尾の改行は保つ
my @line = grep { /\S/ } split /\n/, $text, -1 ;
return @line ? join("\n", @line) . $lf : '' ;
} ;
# ====================
sub trim_line {  # 各行の行頭・行末の空白（全角スペース等も含む）を取り除く
my $text = $_[0] // '' ;
$text =~ s/^\h+//mg ;
$text =~ s/[\h\r]+$//mg ;  # CRLF の CR もここで落とす
return $text ;
} ;
# ====================
sub balance_tag {  # 行をまたぐタグを、行ごとに閉じて開き直す
my ($ref, $tag) = @_ ;
my $open = 0 ;
foreach my $line (@{$ref}){
	$open and $line = "<$tag>" . $line ;
	my $o = () = $line =~ /<$tag>/g ;
	my $c = () = $line =~ m{</$tag>}g ;
	$open = ($o > $c) ? 1 : 0 ;
	$open and $line .= "</$tag>" ;
}
} ;
# ====================
sub merged_equal {  # 1列表示: @a_split の指定位置までを共通部分として取り込む
my $upto = $_[0] // 0 ;
($upto > scalar @a_split) and $upto = scalar @a_split ;
($upto > $m_pos) or return ;
push @merged, ['=', 0, join('', map { $_ // '' } @a_split[$m_pos .. $upto - 1])] ;
$m_pos = $upto ;
} ;
# ====================
sub merged_diff {  # 1列表示: 削除または追加された部分を取り込む
my ($type, $num, $ref, $from, $to) = @_ ;
($from < 0) and $from = 0 ;
($to > $#{$ref}) and $to = $#{$ref} ;
($from > $to) and return ;
push @merged, [$type, $num, join('', map { $_ // '' } @{$ref}[$from .. $to])] ;
} ;
# ====================
sub fifo_send {  # usage: fifo_send($text, $path) ;
my $text = $_[0] // '' ;
my $path = $_[1] or print_html('ERROR : open failed (1)') ;
mkfifo($path, 0600) or print_html('ERROR : open failed (2)') ;
my $pid = fork ;
if ($pid == 0){
	open(FIFO, ">$path") or print_html('ERROR : open failed (3)') ;
	utf8::encode($text) ;  # UTF-8エンコード
	print FIFO $text ;
	close FIFO ;
	unlink $path ;
	exit ;
}
} ;
# ====================
sub escape_char {  # < > & ' " の5文字を実態参照に変換
my $string = $_[0] // '' ;
$string =~ s/\&/&amp;/g ;
$string =~ s/</&lt;/g ;
$string =~ s/>/&gt;/g ;
$string =~ s/\'/&#39;/g ;
$string =~ s/\"/&quot;/g ;
return $string ;
} ;
# ====================
sub escape_space {  # 空白文字を実態参照に変換
my $string = $_[0] // '' ;
$string =~ s/\s/&nbsp;/g ;  # 空白文字（スペース、タブ等含む）はスペースとみなす
return $string ;
} ;
# ====================
sub count_char {  # 文字数をカウント

#- ▼ メモ
# $count1: 改行空白なし文字数
# $count2: 空白あり文字数
# $count3: 改行空白あり文字数
# $wcount: 単語数
#- ▲ メモ

my $text = $_[0] // '' ;

#- ▼ 単語数をカウント
my $words = $text ;
my $wcount = ($words =~ s/\s*\S+//g) ;
#- ▲ 単語数をカウント

#- ▼ 文字数をカウント
$text =~ tr/\r//d ;  # カウントの準備: CRを除去
my $count3 = length($text) ;
$text =~ tr/\n//d ;  # 改行を除去してカウント
my $count2 = length($text) ;
$text =~ s/\s//g ;   # 空白文字を除去してカウント
my $count1 = length($text) ;
#- ▲ 文字数をカウント

return ($count1, $count2, $count3, $wcount) ;
} ;
# ====================
sub print_html {  # HTMLを出力

#- ▼ メモ
# ・比較結果ページを出力（デフォルト）
# ・引数が ERROR で始まる場合はエラーページを出力
# ・引数がない場合はトップページを出力
#- ▲ メモ

my $message = $_[0] // '' ;

#- ▼ エラーページ：引数が ERROR で始まる場合
$message =~ s{^(ERROR.*)$}{<p><font color=red>$1</font></p>}s ;
#- ▲ エラーページ：引数が ERROR で始まる場合

#- ▼ トップページ：引数がない場合
(not $message) and $message = <<'--EOS--'
<div id=news>
<p>最新动态：</p>

<ul>
	<li>2017-08-07　支持 HTTPS 加密连接 -
		<a href='https://difff.jp/'>https://difff.jp/</a>
	<li>2015-06-17　新增公开分享比较结果的功能 (ver.6.1) -
		<a target='_blank' href='http://data.dbcls.jp/~meso/meme/archives/2957'>
			说明（日文）</a>
	<li>2014-03-14　首页地址变更为 <a href='http://difff.jp/'>http://difff.jp/</a>
	<li>2014-03-12　ITmedia 新闻 -
		<a target='_blank' href='http://www.itmedia.co.jp/news/articles/1403/12/news121.html'>
			介绍文本比较工具 difff 的报道（日文）</a>
	<li>2013-12-12　使用教程视频 -
		<a target='_blank' href='http://togotv.dbcls.jp/20130828.html'>
			用 difff 查找文章的改动之处（日文）</a>
	<li>2013-03-12　全面改版 (ver.6) -
		<a target='_blank' href='http://data.dbcls.jp/~meso/meme/archives/2313'>
			更新内容（日文）</a>
	<li>2013-01-11　发布<a href='https://difff.jp/en/'>英文版</a>
	<li>2012-10-22　公开源代码 -
		<a target='_blank' href='https://github.com/meso-cacase/difff'>
			GitHub</a>
	<li>2012-04-16　GIGAZINE -
		<a target='_blank' href='http://gigazine.net/news/20120416-difff/'>
			支持日文、可轻松确认差异的文本比较工具「difff」（日文）</a>
	<li>2012-04-13　全面改版，左右段落不再错位 (ver.5)
	<li>2008-02-18　支持日文 (ver.4)
	<li>2004-02-19　初代 difff 完成 (ver.1)
</ul>
</div>

<hr><!-- ________________________________________ -->

<p><font color=gray>Last modified on Apr 17, 2026 by
<a target='_blank' href='http://twitter.com/meso_cacase'>@meso_cacase</a>
</font></p>
--EOS--

and $sequenceA = <<'--EOS--'
请比较下面的两段文字。
   Betty Botter bought some butter, 
But, she said, this butter's bitter;
If I put it in my batter,
It will make my batter bitter,
But a bit of better butter
Will make my batter better.
So she bought a bit of butter
Better than her bitter butter,
And she put it in her batter,
And it made her batter better,
So 'twas better Betty Botter
Bought a bit of better butter.
--EOS--

and $sequenceB = <<'--EOS--' ;
请对比下面的两段文本，
Betty Botter bought some butter,
But, she said, the butter's bitter;
If I put it in my batter,
That will make my batter bitter.
But a bit of better butter, 
That will make my batter better.
So she bought a bit of butter
Better than her bitter butter.
And she put it in her batter,
And it made her batter better.
So it was better Betty Botter
Bought a bit of better butter.
--EOS--
#- ▲ トップページ：引数がない場合

#- ▼ HTML出力
$sequenceA = escape_char($sequenceA) ;  # XSS対策
$sequenceB = escape_char($sequenceB) ;  # XSS対策

my $html = <<"--EOS--" ;
<!DOCTYPE HTML PUBLIC '-//W3C//DTD HTML 4.01 Transitional//EN'>
<html lang=zh-CN>

<head>
<meta http-equiv='Content-Type' content='text/html; charset=utf-8'>
<meta http-equiv='Content-Script-Type' content='text/javascript'>
<meta http-equiv='Content-Style-Type' content='text/css'>
<meta name='author' content='Yuki Naito'>
<title>difff - 文本比较</title>
<script type='text/javascript'>
<!--
	function hideForm() {
		if (document.getElementById('form').style.display == 'none') {
			document.getElementById('top' ).style.display = 'block';
			document.getElementById('form').style.display = 'block';
			document.getElementById('save').style.display = 'block';
			document.getElementById('hide').value = '仅显示结果 (便于打印)';
		} else {
			document.getElementById('top' ).style.display = 'none';
			document.getElementById('form').style.display = 'none';
			document.getElementById('save').style.display = 'none';
			document.getElementById('hide').value = '显示全部';
		}
	}
	var diffs    = [];   // 2列表示の差分
	var mdiffs   = [];   // 1列表示の差分
	var diffIdx  = -1;
	var mergedOn = false;

	function curDiffs() { return mergedOn ? mdiffs : diffs }

	function initDiffNav() {
		var table = document.getElementById('difftable');
		if (!table) { return }
		var byNum = {};
		var cur   = [null, null];
		for (var r = 0; r < table.rows.length; r++) {
			var cells = table.rows[r].cells;
			var col = 0;  // 行番号のセルは飛ばし、左右の本文セルだけ見る
			for (var c = 0; c < cells.length && col < 2; c++) {
				if (cells[c].className == 'ln') { continue }
				var nodes = cells[c].getElementsByTagName('*');
				for (var i = 0; i < nodes.length; i++) {
					var el = nodes[i];
					if (el.className == 'dm') {
						var n = parseInt(el.id.substring(1), 10);
						if (!byNum[n]) {
							byNum[n] = { num:n, ems:[], mark:el, topEm:null };
							diffs.push(byNum[n]);
						}
						cur[col] = byNum[n];
					} else if (el.tagName.toLowerCase() == 'em' && cur[col]) {
						cur[col].ems.push(el);
						if (!cur[col].topEm) { cur[col].topEm = el }
					}
				}
				col++;
			}
		}
		diffs.sort(function(x, y){ return x.num - y.num });
		for (var k = 0; k < diffs.length; k++) {
			for (var m = 0; m < diffs[k].ems.length; m++) {
				diffs[k].ems[m].onclick = diffClick(k);
				diffs[k].ems[m].style.cursor = 'pointer';
			}
		}
		if (diffs.length) { document.onkeydown = diffKey }
	}
	function diffClick(k) {
		return function(){ showDiff(k) };
	}
	function diffOutline(d, style) {
		for (var i = 0; i < d.ems.length; i++) {
			d.ems[i].style.outline = style;
		}
	}
	function showDiff(k) {
		var list = curDiffs();
		if (!list.length || !list[k]) { return }
		if (diffIdx > -1 && list[diffIdx]) { diffOutline(list[diffIdx], '') }
		diffIdx = k;
		diffOutline(list[k], '2px solid #FF6600');
		var pos = document.getElementById('diffpos');
		if (pos) { pos.innerHTML = (k + 1) + ' / ' + list.length }
		var el = list[k].topEm || list[k].mark;
		var y  = 0;
		while (el) { y += el.offsetTop; el = el.offsetParent }
		var h = window.innerHeight || document.documentElement.clientHeight || 500;
		y = y - Math.floor(h / 3);
		window.scrollTo(0, (y > 0) ? y : 0);
	}
	function gotoDiff(step) {
		var list = curDiffs();
		if (!list.length) { return }
		var k = diffIdx + step;
		if (k < 0) { k = list.length - 1 }
		if (k > list.length - 1) { k = 0 }
		showDiff(k);
	}
	function initMergedNav() {  // 1列表示の差分を集めてナビゲーションに使う
		var m = document.getElementById('merged');
		if (!m) { return }
		var nodes = m.getElementsByTagName('*');
		var cur   = null;
		for (var i = 0; i < nodes.length; i++) {
			var el = nodes[i];
			if (el.className == 'dm') {
				cur = { num:parseInt(el.id.substring(1), 10), ems:[], mark:el, topEm:null };
				mdiffs.push(cur);
			} else if (cur) {
				var tag = el.tagName.toLowerCase();
				if (tag == 'del' || tag == 'ins') {
					cur.ems.push(el);
					if (!cur.topEm) { cur.topEm = el }
				}
			}
		}
		for (var k = 0; k < mdiffs.length; k++) {
			for (var j = 0; j < mdiffs[k].ems.length; j++) {
				mdiffs[k].ems[j].onclick = diffClick(k);
				mdiffs[k].ems[j].style.cursor = 'pointer';
			}
		}
	}
	function toggleMerge(box) {  // 2列表示と1列表示を切り替える
		saveOpt(box);
		var m = document.getElementById('merged');
		var t = document.getElementById('difftable');
		if (!m || !t) { return }
		if (box.checked && !mdiffs.length) { initMergedNav() }
		var prev = curDiffs();
		if (diffIdx > -1 && prev[diffIdx]) { diffOutline(prev[diffIdx], '') }
		diffIdx  = -1;
		mergedOn = box.checked;
		m.style.display = mergedOn ? 'block' : 'none';
		t.style.display = mergedOn ? 'none'  : '';
		// 切り替え先のビューにも「只显示有差异的行」の状態を反映する
		var only  = document.getElementById('onlydiff');
		var built = mergedOn ? mergedSkips : tableSkips;
		if (only && (only.checked || built)) { toggleOnlyDiff(only) }
		var pos = document.getElementById('diffpos');
		if (pos) { pos.innerHTML = '- / ' + curDiffs().length }
		if (curDiffs().length) { document.onkeydown = diffKey }
	}
	function diffKey(e) {
		e = e || window.event;
		if (e.ctrlKey || e.altKey || e.metaKey) { return }
		var t = e.target || e.srcElement;
		if (t && t.tagName) {
			var tag = t.tagName.toLowerCase();
			if (tag == 'textarea' || tag == 'input' || tag == 'select') { return }
		}
		var key = (e.key || String.fromCharCode(e.keyCode || e.which)).toLowerCase();
		if (key == 'n') { gotoDiff(1) } else if (key == 'p') { gotoDiff(-1) }
	}
	var SKIP_TEXT_A = '&hellip;&emsp;已隐藏 ';
	var SKIP_TEXT_B = ' 行相同内容&emsp;&hellip;';
	var SKIP_HINT   = '点击展开这些行';
	var tableSkips  = null;   // 2列表示分
	var mergedSkips = null;   // 1列表示分

	function toggleOnlyDiff(box) {
		saveOpt(box);
		var v = mergedOn ? mergedSkipData() : tableSkipData();
		if (!v) { return }
		for (var i = 0; i < v.plain.length; i++) {
			v.plain[i].style.display = box.checked ? 'none' : '';
		}
		for (var j = 0; j < v.skip.length; j++) {
			v.skip[j].style.display = box.checked ? '' : 'none';
		}
	}
	function tableSkipData() {
		if (tableSkips) { return tableSkips }
		var table = document.getElementById('difftable');
		if (!table) { return null }
		var rows = [];
		for (var i = 0; i < table.rows.length; i++) { rows.push(table.rows[i]) }
		tableSkips = buildSkips(rows, hasEm, newSkipRow);
		return tableSkips;
	}
	function mergedSkipData() {
		if (mergedSkips) { return mergedSkips }
		var box = document.getElementById('mergedtext');
		if (!box) { return null }
		var lines = [];
		var kids  = box.childNodes;
		for (var i = 0; i < kids.length; i++) {
			if (kids[i].className == 'ml') { lines.push(kids[i]) }
		}
		mergedSkips = buildSkips(lines, hasDelIns, newSkipLine);
		return mergedSkips;
	}
	function hasEm(el) { return el.getElementsByTagName('em').length }
	function hasDelIns(el) {
		return el.getElementsByTagName('del').length +
		       el.getElementsByTagName('ins').length;
	}
	function newSkipRow(n) {
		var td = document.createElement('td');
		td.colSpan   = 4;  // 行番号セルの分
		td.className = 'skip';
		td.innerHTML = SKIP_TEXT_A + n + SKIP_TEXT_B;
		var tr = document.createElement('tr');
		tr.appendChild(td);
		return tr;
	}
	function newSkipLine(n) {
		var div = document.createElement('div');
		div.className = 'mskip';
		div.innerHTML = SKIP_TEXT_A + n + SKIP_TEXT_B;
		return div;
	}
	function buildSkips(items, hasDiff, newSkip) {
		var plain = [], skip = [], run = [];
		for (var k = 0; k < items.length; k++) {
			if (hasDiff(items[k])) {
				addSkip(items[k], run, plain, skip, newSkip);
				run = [];
			} else {
				run.push(items[k]);
			}
		}
		addSkip(null, run, plain, skip, newSkip);  // 末尾に残った同じ行
		return { plain:plain, skip:skip };
	}
	function addSkip(before, run, plain, skip, newSkip) {
		if (!run.length) { return }
		for (var i = 0; i < run.length; i++) { plain.push(run[i]) }
		var el = newSkip(run.length);
		el.title = SKIP_HINT;
		el.style.display = 'none';
		el.onclick = skipClick(el, run);
		if (before) {
			before.parentNode.insertBefore(el, before);
		} else {
			run[run.length - 1].parentNode.appendChild(el);
		}
		skip.push(el);
	}
	function skipClick(el, run) {
		return function(){
			for (var i = 0; i < run.length; i++) { run[i].style.display = '' }
			el.style.display = 'none';
		};
	}
	var THEME_DARK  = '深色主题';
	var THEME_LIGHT = '浅色主题';

	function applyTheme(dark) {
		document.body.className = dark ? 'dark' : '';
		var btn = document.getElementById('themebtn');
		if (btn) { btn.value = dark ? THEME_LIGHT : THEME_DARK }
	}
	function toggleTheme() {
		var dark = (document.body.className != 'dark');
		applyTheme(dark);
		try { localStorage.setItem('difffTheme', dark ? 'dark' : 'light') } catch (e) {}
	}
	function initTheme() {
		var saved = '';
		try { saved = localStorage.getItem('difffTheme') } catch (e) {}
		applyTheme(saved == 'dark');
	}
	var MAXFILESIZE      = 10485760;  // 10MB
	var FILE_TOOBIG      = '文件太大，请换一个更小的文件。';
	var FILE_READERROR   = '读取文件失败。';
	var FILE_UNSUPPORTED = '当前浏览器不支持读取本地文件。';

	function lsGet(key, def) {
		try {
			var v = localStorage.getItem(key);
			return (v === null) ? def : v;
		} catch (e) { return def }
	}
	function lsSet(key, val) {
		try { localStorage.setItem(key, val) } catch (e) {}
	}
	function saveOpt(box) { lsSet('difff_' + box.id, box.checked ? '1' : '0') }
	function getOpt(id, def) { return lsGet('difff_' + id, def) == '1' }

	function toggleLineNo(box) {  // 行番号の表示・非表示
		saveOpt(box);
		var cls = box.checked ? '' : 'noln';
		var t = document.getElementById('difftable');
		var c = document.getElementById('charcount');
		if (t) { t.className = cls }
		if (c) { c.className = cls }
	}
	function initOptions() {  // 前回の選択を復元する
		if (!document.getElementById('result')) {
			// トップページ: 入力オプションを復元する
			restoreBox('ignoreblank');
			restoreBox('ignorecase');
			restoreBox('trimspace');
			return;
		}
		// 結果ページ: 入力オプションはサーバが返した状態のままにし、表示だけ復元する
		var ln = document.getElementById('showln');
		if (ln) { ln.checked = getOpt('showln', '1'); toggleLineNo(ln) }
		var mg = document.getElementById('mergeview');
		if (mg && getOpt('mergeview', '0')) { mg.checked = true; toggleMerge(mg) }
		var od = document.getElementById('onlydiff');
		if (od && getOpt('onlydiff', '0')) { od.checked = true; toggleOnlyDiff(od) }
		restoreColor(lsGet('difff_color', '1'));
	}
	function restoreBox(id) {
		var box = document.getElementById(id);
		if (box) { box.checked = getOpt(id, '0') }
	}
	function restoreColor(color) {
		if (color == '1') { return }
		var list = document.getElementsByName('color');
		for (var i = 0; i < list.length; i++) {
			if (list[i].value == color) { list[i].checked = true }
		}
		if (color == '2') { setColor2() } else if (color == '3') { setColor3() }
	}
	function initFileDrop() {  // テキストエリアへのファイルのドロップを受け付ける
		var ids = ['sequenceA', 'sequenceB'];
		for (var i = 0; i < ids.length; i++) {
			var ta = document.getElementById(ids[i]);
			if (!ta) { continue }
			if (!window.FileReader) {  // 読み込めないブラウザではボタンを隠す
				var f = document.getElementById(i ? 'fileB' : 'fileA');
				if (f && f.parentNode) { f.parentNode.style.display = 'none' }
				continue;
			}
			ta.ondragover  = dragOver;
			ta.ondragenter = dragOver;
			ta.ondragleave = dragEnd;
			ta.ondrop      = dropFile;
		}
	}
	function hasFiles(e) {  // ファイルのドロップかどうか
		var dt = e.dataTransfer;
		if (!dt) { return false }
		if (dt.files && dt.files.length) { return true }
		var t = dt.types;
		if (!t) { return false }
		for (var i = 0; i < t.length; i++) { if (t[i] == 'Files') { return true } }
		return false;
	}
	function stopEvent(e) {
		if (e.preventDefault) { e.preventDefault() } else { e.returnValue = false }
	}
	function dragOver(e) {
		e = e || window.event;
		if (!hasFiles(e)) { return true }  // 文字のドロップは既定の動作にまかせる
		stopEvent(e);
		(e.target || e.srcElement).className = 'dragover';
		return false;
	}
	function dragEnd(e) {
		e = e || window.event;
		(e.target || e.srcElement).className = '';
		return true;
	}
	function dropFile(e) {
		e = e || window.event;
		var ta = e.target || e.srcElement;
		ta.className = '';
		if (!hasFiles(e)) { return true }
		stopEvent(e);
		readFile(e.dataTransfer.files[0], ta);
		return false;
	}
	function pickFile(input, id) {
		var ta = document.getElementById(id);
		if (ta && input.files && input.files.length) { readFile(input.files[0], ta) }
		input.value = '';  // 同じファイルを選び直したときも読み込めるようにする
	}
	function readFile(file, ta) {
		if (!window.FileReader) { alert(FILE_UNSUPPORTED); return }
		if (file.size > MAXFILESIZE) { alert(FILE_TOOBIG); return }
		var reader = new FileReader();
		reader.onload  = function(ev){ ta.value = ev.target.result };
		reader.onerror = function(){ alert(FILE_READERROR) };
		reader.readAsText(file, 'utf-8');
	}
	function setMergedPlain(plain) {  // 1列表示を白黒（印刷向け）にする
		var m = document.getElementById('merged');
		if (m) { m.className = plain ? 'plain' : '' }
	}
	function setColor1() {
		lsSet('difff_color', '1');
		document.getElementById('top').style.borderTop = '5px solid #00BBFF';
		setMergedPlain(false);
		var emList = document.getElementsByTagName('em');
		for (i = 0; i < emList.length; i++) {
			emList[i].className = 'blue' ;
		}
	}
	function setColor2() {
		lsSet('difff_color', '2');
		document.getElementById('top').style.borderTop = '5px solid #00bb00';
		setMergedPlain(false);
		var emList = document.getElementsByTagName('em');
		for (i = 0; i < emList.length; i++) {
			emList[i].className = 'green' ;
		}
	}
	function setColor3() {
		lsSet('difff_color', '3');
		document.getElementById('top').style.borderTop = '5px solid black';
		setMergedPlain(true);
		var emList = document.getElementsByTagName('em');
		for (i = 0; i < emList.length; i++) {
			emList[i].className = 'black' ;
		}
	}
	function savehtml() {
		addHidden('sequenceA', document.difff.sequenceA.value);
		addHidden('sequenceB', document.difff.sequenceB.value);
		var opt = ['ignoreblank', 'ignorecase', 'trimspace'];
		for (var i = 0; i < opt.length; i++) {
			var box = document.getElementById(opt[i]);
			if (box && box.checked) { addHidden(opt[i], '1') }
		}
		return confirm('确定要公开吗？\\n[确定] → 公开此结果，并跳转到该页面。');
	}
	function addHidden(name, value) {
		var el = document.createElement('input');
		el.setAttribute('type', 'hidden');
		el.setAttribute('name', name);
		el.setAttribute('value', value);
		document.save.appendChild(el);
	}
//-->
</script>
<style type='text/css'>
<!--
	* { font-family:verdana,arial,helvetica,sans-serif }
	p,table,textarea,ul { font-size:10pt }
	textarea { width:100% }
	a  { color:#3366CC }
	.k { color:black; text-decoration:none }
	em { font-style:normal }
	em,
	.blue  { font-weight:bold; color:black; background:#99EEFF; border:1px solid #00BBFF }
	.green { font-weight:bold; color:black; background:#99FF99; border:none }
	.black { font-weight:bold; color:white; background:black;   border:none }
	#diffnav {
		position:sticky;
		top:0;
		z-index:10;
		padding:8px 20px;
		font-size:10pt;
		background:#F4F4F4;
		border-bottom:solid 1px silver;
	}
	#diffnav label {
		white-space:nowrap;
	}
	#diffnav.same {
		background:#99EEFF;
		border-bottom:solid 1px #00BBFF;
	}
	table {
		width:95%;
		margin:20px;
		table-layout:fixed;
		word-wrap:break-word;
		border-collapse:collapse;
	}
	td {
		padding:4px 15px;
		vertical-align:top;
		border-left:solid 1px silver;
		border-right:solid 1px silver;
	}
	col.lncol { width:4.5em }
	td.ln {
		padding:4px 8px 4px 4px;
		color:gray;
		font-size:9pt;
		text-align:right;
		white-space:nowrap;
		border-right:none;
		-webkit-user-select:none;
		user-select:none;
	}
	td.ln + td { border-left:none }
	table.noln td.ln { display:none }
	table.noln col.lncol { width:0 }
	textarea.dragover { outline:2px dashed #00BBFF }
	.fileline { margin-top:4px }
	.fileline input { font-size:8pt }
	td.skip {
		padding:2px 15px;
		color:gray;
		font-size:9pt;
		text-align:center;
		background:#FAFAFA;
		cursor:pointer;
	}
	#merged {
		width:95%;
		margin:20px;
		font-size:10pt;
		line-height:1.8;
	}
	#mergedhint {
		margin-bottom:8px;
	}
	#mergedtext {
		white-space:pre-wrap;
		word-wrap:break-word;
		overflow-wrap:anywhere;
	}
	#mergedtext .mskip {
		display:block;
		padding:2px 15px;
		color:gray;
		font-size:9pt;
		text-align:center;
		background:#FAFAFA;
		cursor:pointer;
	}
	#merged del {
		color:#A00000;
		background:#FFDDDD;
		border:solid 1px #FFAAAA;
		text-decoration:line-through;
	}
	#merged ins {
		color:#006600;
		background:#CCFFCC;
		border:solid 1px #66CC66;
		text-decoration:none;
	}
	#merged.plain del,
	#merged.plain ins {
		color:black;
		background:none;
		border:none;
	}
	#merged.plain del { text-decoration:line-through }
	#merged.plain ins { text-decoration:underline }
	table#passwd {
		width:auto;
		border:dotted 1px #8c93ba;
	}
	.n { border:none }
	body { background:#FFFFFF; color:#000000 }
	body.dark { background:#1E1E1E; color:#DDDDDD }
	body.dark a { color:#6FB3FF }
	body.dark .k { color:#DDDDDD }
	body.dark font { color:#999999 }
	body.dark hr { border-color:#444444; background:#444444; color:#444444 }
	body.dark textarea {
		background:#2A2A2A;
		color:#DDDDDD;
		border:solid 1px #555555;
	}
	body.dark table { color:#DDDDDD }  /* 互換モードでは table が body から色を継承しない */
	body.dark td { border-left-color:#444444; border-right-color:#444444 }
	body.dark td.skip { background:#262626; color:#888888 }
	body.dark #mergedtext .mskip { background:#262626; color:#888888 }
	body.dark #diffnav { background:#2A2A2A; border-bottom-color:#444444 }
	body.dark #diffnav.same {
		background:#99EEFF;
		border-bottom-color:#00BBFF;
		color:black;
	}
	body.dark td.ln { color:#888888 }
	body.dark table#passwd { border-color:#666688 }
	body.dark #merged del {
		color:#FFBBBB;
		background:#4A2020;
		border-color:#7A3838;
	}
	body.dark #merged ins {
		color:#AAFFAA;
		background:#1E3D1E;
		border-color:#3A6E3A;
	}
	body.dark #merged.plain del,
	body.dark #merged.plain ins {
		color:#DDDDDD;
		background:none;
		border:none;
	}
-->
</style>
</head>

<body onload='initTheme(); initDiffNav(); initFileDrop(); initOptions()'>
<script type='text/javascript'>initTheme();</script>

<div id=top style='border-top:5px solid #00BBFF; padding-top:10px'>
<font size=5>
	<a class=k href='$url'>
	文本比较工具 <b>difff</b></a></font><!--
--><font size=3>ver.6.1</font>
&emsp;
<font size=1 style='vertical-align:16px'>
	<a href='${url}en/'>English</a> |
	简体中文
</font>
&emsp;
<font size=1 style='vertical-align:16px'>
<a href='${url}v5/'>旧版本 (ver.5)</a>
</font>
&emsp;
	<input type=button id=themebtn value='深色主题' onclick='toggleTheme()'
		style='font-size:8pt; vertical-align:14px'>
<hr><!-- ________________________________________ -->
</div>

<div id=form>
<p>请在下面两个框中输入要比较的文本，将显示两者的差异 (diff)。</p>

<form method=POST id=difff name=difff action='$url'>
<table cellspacing=0>
<tr>
	<td class=n><textarea name=sequenceA id=sequenceA rows=20>$sequenceA</textarea>
		<div class=fileline><input type=file id=fileA onchange='pickFile(this, "sequenceA")'><!--
		--><font color=gray size=1>也可以把文件拖到上面的框里</font></div></td>
	<td class=n><textarea name=sequenceB id=sequenceB rows=20>$sequenceB</textarea>
		<div class=fileline><input type=file id=fileB onchange='pickFile(this, "sequenceB")'><!--
		--><font color=gray size=1>也可以把文件拖到上面的框里</font></div></td>
</tr>
</table>

<p><input type=submit value='比较'>
&emsp;<input type=checkbox name=ignoreblank id=ignoreblank value=1@{[$ignoreblank ? ' checked' : '']} onclick='saveOpt(this)'><!--
--><label for=ignoreblank>忽略空行</label><!--
-->&emsp;<input type=checkbox name=ignorecase id=ignorecase value=1@{[$ignorecase ? ' checked' : '']} onclick='saveOpt(this)'><!--
--><label for=ignorecase>忽略大小写</label><!--
-->&emsp;<input type=checkbox name=trimspace id=trimspace value=1@{[$trimspace ? ' checked' : '']} onclick='saveOpt(this)'><!--
--><label for=trimspace>忽略行首尾空白</label></p>
</form>
</div>

$message

</body>
</html>
--EOS--

print "Content-type: text/html; charset=utf-8\n\n$html" ;
#- ▲ HTML出力

exit ;
} ;
# ====================

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

binmode STDOUT, ':utf8' ;        # 標準出力をUTF-8エンコード
binmode STDERR, ':utf8' ;        # 標準エラー出力をUTF-8エンコード

# ▼ HTTPリクエストからクエリを取得し整形してFIFOに送る
my %query = get_query_parameters() ;

my $sequenceA = $query{'sequenceA'} // '' ;
utf8::decode($sequenceA) ;  # utf8フラグを有効にする

my $sequenceB = $query{'sequenceB'} // '' ;
utf8::decode($sequenceB) ;  # utf8フラグを有効にする

# 両方とも空欄のときはトップページを表示
$sequenceA eq '' and $sequenceB eq '' and print_html() ;

my $fifopath_a = "$fifodir/difff.$$.A" ;  # $$はプロセスID
my @a_split = split_text( escape_char($sequenceA) ) ;
my $a_split = join("\n", @a_split) . "\n" ;
fifo_send($a_split, $fifopath_a) ;

my $fifopath_b = "$fifodir/difff.$$.B" ;  # $$はプロセスID
my @b_split = split_text( escape_char($sequenceB) ) ;
my $b_split = join("\n", @b_split) . "\n" ;
fifo_send($b_split, $fifopath_b) ;
# ▲ HTTPリクエストからクエリを取得し整形してFIFOに送る

# ▼ diffコマンドの実行
(-e $diffcmd) or print_html("ERROR : $diffcmd : not found") ;
(-x $diffcmd) or print_html("ERROR : $diffcmd : not executable") ;
my @diffout = `$diffcmd -d $fifopath_a $fifopath_b` ;
my @diffsummary = grep /(^[^<>-]|<\$>)/, @diffout ;
# ▲ diffコマンドの実行

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
		my $i = ($a_start > 1) ? $a_start - 2 : 0 ;
		while ($i < @a_split and not $a_split[$i] =~ s/<\$>/<\$><\$>/){ $i ++ }
	} elsif ($_ =~ /< <\$>/){  # 改行の数をあわせる処理
		my $i = ($b_start > 1) ? $b_start - 2 : 0 ;
		while ($i < @b_split and not $b_split[$i] =~ s/<\$>/<\$><\$>/){ $i ++ }
	}
}
# ▲ 差分の検出とHTMLタグの埋め込み

# ▼ 比較結果のブロックを生成してHTMLを出力
my $a_final = join '', @a_split ;
my $b_final = join '', @b_split ;

# 変更箇所が<td>をまたぐ場合の処理、該当箇所がなくなるまで繰り返し適用
while ( $a_final =~ s{(<em>[^<>]*)<\$>(([^<>]|<\$>)*</em>)}{$1</em><\$><em>$2}g ){}
while ( $b_final =~ s{(<em>[^<>]*)<\$>(([^<>]|<\$>)*</em>)}{$1</em><\$><em>$2}g ){}

my @a_final = split /<\$>/, $a_final ;
my @b_final = split /<\$>/, $b_final ;

my $par = (@a_final > @b_final) ? @a_final : @b_final ;

my $table = '' ;
foreach (0..$par-1){
	defined $a_final[$_] or $a_final[$_] = '' ;
	defined $b_final[$_] or $b_final[$_] = '' ;
	$a_final[$_] =~ s{(\ +</em>)}{escape_space($1)}ge ;
	$b_final[$_] =~ s{(\ +</em>)}{escape_space($1)}ge ;
	$table .=
"<tr>
	<td>$a_final[$_]</td>
	<td>$b_final[$_]</td>
</tr>
" ;
}

#- ▽ 文字数をカウントしてtableに付加
my ($count1_A, $count2_A, $count3_A, $wcount_A) = count_char($sequenceA) ;
my ($count1_B, $count2_B, $count3_B, $wcount_B) = count_char($sequenceB) ;

$table .= <<"--EOS--" ;
<tr>
	<td><font color=gray>
		字符数: $count1_A<br>
		空格数: @{[$count2_A - $count1_A]} 含空格字符数: $count2_A<br>
		换行数: @{[$count3_A - $count2_A]} 含换行字符数: $count3_A<br>
		词数: $wcount_A
	</font></td>
	<td><font color=gray>
		字符数: $count1_B<br>
		空格数: @{[$count2_B - $count1_B]} 含空格字符数: $count2_B<br>
		换行数: @{[$count3_B - $count2_B]} 含换行字符数: $count3_B<br>
		词数: $wcount_B
	</font></td>
</tr>
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
<font color=gray size=1>&emsp;也可以按 n / p 键跳转</font>
</div>
" :
"<div id=diffnav class=same>
<b>没有不同（两边内容完全一致）</b>
</div>
" ;
#- △ 差分の総数と移動ボタンを生成

my $message = <<"--EOS--" ;
<div id=result>
$navbar<table cellspacing=0>
$table</table>

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
length $buffer > 5000000 and print_html('ERROR : input too large') ;
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
my @text ;
while ($text =~ s/^([a-z]+|<\$>|&\#?\w+;|.)//){
	push @text, $1 ;
}
return @text ;
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
	var diffs   = [];
	var diffIdx = -1;

	function initDiffNav() {
		var result = document.getElementById('result');
		if (!result) { return }
		var table = result.getElementsByTagName('table')[0];
		if (!table) { return }
		var byNum = {};
		var cur   = [null, null];
		for (var r = 0; r < table.rows.length; r++) {
			var cells = table.rows[r].cells;
			for (var c = 0; c < cells.length && c < 2; c++) {
				var nodes = cells[c].getElementsByTagName('*');
				for (var i = 0; i < nodes.length; i++) {
					var el = nodes[i];
					if (el.className == 'dm') {
						var n = parseInt(el.id.substring(1), 10);
						if (!byNum[n]) {
							byNum[n] = { num:n, ems:[], mark:el, topEm:null };
							diffs.push(byNum[n]);
						}
						cur[c] = byNum[n];
					} else if (el.tagName.toLowerCase() == 'em' && cur[c]) {
						cur[c].ems.push(el);
						if (!cur[c].topEm) { cur[c].topEm = el }
					}
				}
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
		if (!diffs.length) { return }
		if (diffIdx > -1) { diffOutline(diffs[diffIdx], '') }
		diffIdx = k;
		diffOutline(diffs[k], '2px solid #FF6600');
		var pos = document.getElementById('diffpos');
		if (pos) { pos.innerHTML = (k + 1) + ' / ' + diffs.length }
		var el = diffs[k].topEm || diffs[k].mark;
		var y  = 0;
		while (el) { y += el.offsetTop; el = el.offsetParent }
		var h = window.innerHeight || document.documentElement.clientHeight || 500;
		y = y - Math.floor(h / 3);
		window.scrollTo(0, (y > 0) ? y : 0);
	}
	function gotoDiff(step) {
		if (!diffs.length) { return }
		var k = diffIdx + step;
		if (k < 0) { k = diffs.length - 1 }
		if (k > diffs.length - 1) { k = 0 }
		showDiff(k);
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
	var skipRows  = null;
	var plainRows = null;

	function toggleOnlyDiff(box) {
		var result = document.getElementById('result');
		if (!result) { return }
		var table = result.getElementsByTagName('table')[0];
		if (!table) { return }
		if (!plainRows) { buildSkipRows(table) }
		for (var i = 0; i < plainRows.length; i++) {
			plainRows[i].style.display = box.checked ? 'none' : '';
		}
		for (var j = 0; j < skipRows.length; j++) {
			skipRows[j].style.display = box.checked ? '' : 'none';
		}
	}
	function buildSkipRows(table) {
		plainRows = [];
		skipRows  = [];
		var rows = [];
		for (var i = 0; i < table.rows.length; i++) { rows.push(table.rows[i]) }
		var last = rows.length - 1;
		var run  = [];
		for (var k = 0; k < last; k++) {
			if (rows[k].getElementsByTagName('em').length) {
				addSkipRow(rows[k], run);
				run = [];
			} else {
				run.push(rows[k]);
			}
		}
		if (last > -1) { addSkipRow(rows[last], run) }
	}
	function addSkipRow(before, run) {
		if (!run.length) { return }
		for (var i = 0; i < run.length; i++) { plainRows.push(run[i]) }
		var td = document.createElement('td');
		td.colSpan   = 2;
		td.className = 'skip';
		td.innerHTML = SKIP_TEXT_A + run.length + SKIP_TEXT_B;
		td.title     = SKIP_HINT;
		var tr = document.createElement('tr');
		tr.appendChild(td);
		tr.style.display = 'none';
		tr.onclick = skipClick(tr, run);
		before.parentNode.insertBefore(tr, before);
		skipRows.push(tr);
	}
	function skipClick(tr, run) {
		return function(){
			for (var i = 0; i < run.length; i++) { run[i].style.display = '' }
			tr.style.display = 'none';
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
	function setColor1() {
		document.getElementById('top').style.borderTop = '5px solid #00BBFF';
		var emList = document.getElementsByTagName('em');
		for (i = 0; i < emList.length; i++) {
			emList[i].className = 'blue' ;
		}
	}
	function setColor2() {
		document.getElementById('top').style.borderTop = '5px solid #00bb00';
		var emList = document.getElementsByTagName('em');
		for (i = 0; i < emList.length; i++) {
			emList[i].className = 'green' ;
		}
	}
	function setColor3() {
		document.getElementById('top').style.borderTop = '5px solid black';
		var emList = document.getElementsByTagName('em');
		for (i = 0; i < emList.length; i++) {
			emList[i].className = 'black' ;
		}
	}
	function savehtml() {
		var element1 = document.createElement('input');
		element1.setAttribute('type', 'hidden');
		element1.setAttribute('name', 'sequenceA');
		element1.setAttribute('value', document.difff.sequenceA.value);
		document.save.appendChild(element1);

		var element2 = document.createElement('input');
		element2.setAttribute('type', 'hidden');
		element2.setAttribute('name', 'sequenceB');
		element2.setAttribute('value', document.difff.sequenceB.value);
		document.save.appendChild(element2);

		return confirm('确定要公开吗？\\n[确定] → 公开此结果，并跳转到该页面。');
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
		border-left:solid 1px silver;
		border-right:solid 1px silver;
	}
	td.skip {
		padding:2px 15px;
		color:gray;
		font-size:9pt;
		text-align:center;
		background:#FAFAFA;
		cursor:pointer;
	}
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
	body.dark td { border-left-color:#444444; border-right-color:#444444 }
	body.dark td.skip { background:#262626; color:#888888 }
	body.dark #diffnav { background:#2A2A2A; border-bottom-color:#444444 }
	body.dark #diffnav.same {
		background:#99EEFF;
		border-bottom-color:#00BBFF;
		color:black;
	}
	body.dark table#passwd { border-color:#666688 }
-->
</style>
</head>

<body onload='initTheme(); initDiffNav()'>
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
	<td class=n><textarea name=sequenceA rows=20>$sequenceA</textarea></td>
	<td class=n><textarea name=sequenceB rows=20>$sequenceB</textarea></td>
</tr>
</table>

<p><input type=submit value='比较'></p>
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

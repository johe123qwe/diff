#!/usr/bin/perl

# テキスト比較ツール difff《ﾃﾞｭﾌﾌ》： 2つのテキストの差分をハイライト表示するCGI
#
# 比較するテキストとして、HTTPリクエストから sequenceA および sequenceB を取得し、
# diffコマンドを用いて文字ごと（英単語は単語ごと）に比較し差分をハイライト表示する
#
# 2015-06-11 Yuki Naito (@meso_cacase) difff.plをもとにsave.cgiを作成

use warnings ;
use strict ;
use utf8 ;
use POSIX ;
use Digest::MD5 qw(md5_hex) ;

my $url = './' ;

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

<h4>删除此页面</h4>

<form method=POST id=save name=save action='${url}delete.cgi'>
<p>请输入公开此页面时设置的<b>删除密码</b>。</p>

<table id=passwd>
<tr>
	<td class=n>删除密码：<input type=text name=passwd size=10 value=''></td>
	<td class=n>如果忘记了设置的密码，<br>将无法删除。</td>
</tr>
</table>

<input type=submit onclick='return deletehtml();' value='删除'>

<p>此功能处于试运行阶段，可能会在不预先通知的情况下停止提供。</p>
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
# ・引数がない場合はトップページへリダイレクト
#- ▲ メモ

my $message = $_[0] // '' ;
my $save    = 1 ;

#- ▼ エラーページ：引数が ERROR で始まる場合
$message =~ s{^(ERROR.*)$}{<p><font color=red>$1</font></p>}s and
$save = 0 ;
#- ▲ エラーページ：引数が ERROR で始まる場合

#- ▼ トップページ：引数がない場合
(not $message) and redirect_page($url) ;
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
	function deletehtml() {
		return confirm('确定要删除吗？\\n此操作无法撤销。');
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
	body.dark table { color:#DDDDDD }  /* 互換モードでは table が body から色を継承しない */
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

if ($save){
	my $filename = save_html($html) ;  # HTMLを保存
	redirect_page($filename) ;         # そのページにリダイレクトする
} else {
	print "Content-type: text/html; charset=utf-8\n\n$html" ;
}
#- ▲ HTML出力

exit ;
} ;
# ====================
sub save_html {  # HTMLを保存する
my $html = $_[0] // '' ;

# 削除パスワードのhashを取得。ファイル名の一部に埋め込む
my $md5 = md5_hex($query{'passwd'}) ;

# ランダムな5文字のファイル名を生成（例：nw4c6.html）
# 32^5 = 33,554,432 通りのファイル名をつけられるのでほぼ重複しない
my @char = ('a'..'k', 'm', 'n', 'p'..'z', '2'..'9') ;  # 0,o,1,lは使わない
my $filename =
	$char[rand(@char)] .
	$char[rand(@char)] .
	$char[rand(@char)] .
	$char[rand(@char)] .
	$char[rand(@char)] .
	'.html' ;

# 同名のファイルが既に存在する場合はエラーを返す
(-e "data/$filename") and print_html('ERROR : cannot save file (1)') ;

# HTMLをファイルとして保存。削除パスワードのhashをファイル名の一部に埋め込む
# （例：81dc9bdb52d04dc20036dbd8313ed055_nw4c6.html）
open  FILE, ">data/${md5}_${filename}"
	or print_html('ERROR : cannot save file (2)') ;
print FILE $html ;
close FILE ;

# ブラウザからはアクセスするのはこちらのファイル
# （nw4c6.html -> 81dc9bdb52d04dc20036dbd8313ed055_nw4c6.html）
symlink "${md5}_${filename}", "data/$filename"
	or print_html('ERROR : cannot save file (3)') ;

return $filename ;
} ;
# ====================
sub redirect_page {  # リダイレクトする
my $uri = $_[0] // '' ;
print "Location: $uri\n\n" ;
exit ;
} ;
# ====================

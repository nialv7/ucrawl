///Syntax
/// @url@ { sub } | ~(regex) { sub } | /* dcode */
/// url and str can contain '$number' for capture groups in the
/// inner most regex. ~regex will match webpage fetched from inner most @url
import sdpc, sdpc.combinators;
import std.regex, std.conv;
alias token_ws(string T) = between!(skip_whitespace, token!T, skip_whitespace);
@safe:
int funcCount = 0;
struct Func {
	string name;
	string d_code;
}
ParseResult!(Func[]) parse_blocks(Stream i) {
	return many!(choice!(
		parse_url_block,
		parse_regex_block,
		parse_d_block,
	))(i);
}
auto parse_d_block(Stream i) {
	auto re = Reason(i, "d_block");
	auto v1 = discard!(token_ws!"/*")(i);
	if (!v1.ok)
		return err_result!Func(v1.r);
	char[] d_code = [];
	while(lookahead!(token_ws!"*/", true)(i).ok)
		d_code ~= i.advance(1);
	auto v2 = discard!(token_ws!("*/"))(i);
	auto fn = Func("func"~to!string(funcCount++), "");
	fn.d_code = "void "~fn.name~"(){\n"~d_code.idup~"}";
	return ok_result(fn, v1.consumed+v2.consumed+d_code.length, re);
}
auto parse_url_block(Stream i) {
	auto re = seq!(
		discard!(token_ws!"@"),
		many!(not_ch!"@", false),
		discard!(token_ws!"@"),
		discard!(token_ws!"{"),
		parse_blocks,
		discard!(token_ws!"}")
	)(i);
	if (!re.ok)
		return err_result!Func(re.r);
	//Split on $ but not $$
	auto pattern = ctRegex!"(?<!\\$)\\$(?!\\$)";
	auto cap = ctRegex!"^[a-zA-Z0-9]+";
	char[][] urlparts = split(re.result!0, pattern);
	//Gen code to fetch webpage
	string res = "char url[] = [];\n";
	if (urlparts[0] != "")
		res ~= "url ~= \""~urlparts[0]~"\";\n";
	foreach(part; urlparts[1..$]) {
		char[] rep, left;
		char[] unesc = replaceAll(part, ctRegex!"\\$\\$", "$");
		//replace '$$' with '$'
		if (unesc[0] == '{') {
			auto m = matchFirst(unesc[1..$], cap);
			if (m.length == 0) {
				re.r.msg = "Invalid URL";
				return err_result!Func(re.r);
			}
			rep = "capture[\""~m.hit~"\"]";
			left = unesc[1+m.hit.length..$];
		} else {
			auto m = matchFirst(unesc, ctRegex!"^\\d+");
			if (m.length == 0) {
				re.r.msg = "Invalid URL";
				return err_result!Func(re.r);
			}
			rep = "capture["~m.hit~"]";
			left = unesc[m.hit.length..$];
		}
		import std.string;
		string[dchar] transtable = ['\\' : "\\\\", '"' : "\\\""];
		left = translate(left, transtable);
		res ~= "url ~= "~rep~"~\""~left~"\";\n";
	}
	res ~= "char[] webpage = get(url);\n";
	foreach(f; re.result!1)
		res ~= f.d_code;
	foreach(f; re.result!1)
		res ~= f.name~"();\n";
	auto fn = Func("func"~to!string(funcCount++), "");
	fn.d_code = "void "~fn.name~"(){\n"~res~"}";
	return ok_result!Func(fn, re.consumed, re.r);
}
auto parse_regex_block(Stream i) {
	i.push();
	auto re = token_ws!"~"(i);
	if (!re.ok()) {
		i.pop();
		return err_result!Func(re.r);
	}
	if (i.eof()) {
		i.pop();
		re.r.msg = "EOF";
		return err_result!Func(re.r);
	}
	i.push();
	string quote = i.advance(1);
	char[] regex;
	while(!i.eof()) {
		string now = i.advance(1);
		if (now == quote)
			goto success;
		regex ~= now;
	}
	i.pop();
	re.r.msg = "EOF";
	return err_result!Func(re.r);
success:
	i.drop();
	auto re2 = between!(token_ws!"{", parse_blocks, token_ws!"}")(i);
	if (!re2.ok) {
		i.pop();
		return err_result!Func(re2.r);
	}
	string res = "Captures!(char[]) capture;\n";
	foreach(f; re2.result)
		res ~= f.d_code;
	res ~= "foreach(c; matchAll(webpage, ctRegex!\""~regex~"\")){\ncapture = c;\n";
	foreach(f; re2.result)
		res ~= f.name~"();\n";
	res ~= "}\n";
	auto fn = Func("func"~to!string(funcCount++), "");
	fn.d_code = "void "~fn.name~"(){\n"~res~"}";
	return ok_result!Func(fn, re.consumed+2+regex.length+re2.consumed, re.r);
}
@trusted
void main(string[] arg) {
	import std.file, std.stdio;
	string s = readText(arg[1]);
	auto bs = new BufStream(s);
	auto res = parse_url_block(bs);
	if (!res.ok)
		writeln(res.r.explain);
	else {
		auto outf = stdout;
		if (arg.length > 2)
			outf = File(arg[2], "w");
		outf.writeln("import std.stdio, std.regex, std.net.curl;\n");
		outf.writeln(res.d_code);
		outf.writeln("void main(){\n"~res.name~"();\n}");
	}

}



/* -*- mode: fundamental; indent-tabs-mode: t; -*- */
%{

/*
 * Copyright (c) 2021 Omar Polo <op@omarpolo.com>
 *
 * Permission to use, copy, modify, and distribute this software for any
 * purpose with or without fee is hereby granted, provided that the above
 * copyright notice and this permission notice appear in all copies.
 *
 * THE SOFTWARE IS PROVIDED "AS IS" AND THE AUTHOR DISCLAIMS ALL WARRANTIES
 * WITH REGARD TO THIS SOFTWARE INCLUDING ALL IMPLIED WARRANTIES OF
 * MERCHANTABILITY AND FITNESS. IN NO EVENT SHALL THE AUTHOR BE LIABLE FOR
 * ANY SPECIAL, DIRECT, INDIRECT, OR CONSEQUENTIAL DAMAGES OR ANY DAMAGES
 * WHATSOEVER RESULTING FROM LOSS OF USE, DATA OR PROFITS, WHETHER IN AN
 * ACTION OF CONTRACT, NEGLIGENCE OR OTHER TORTIOUS ACTION, ARISING OUT OF
 * OR IN CONNECTION WITH THE USE OR PERFORMANCE OF THIS SOFTWARE.
 */

#include <errno.h>
#include <stdarg.h>
#include <stdio.h>
#include <string.h>

#include "gmid.h"

/*
 * #define YYDEBUG 1
 * int yydebug = 1;
 */

struct vhost *host;
size_t ihost;
struct location *loc;
size_t iloc;

int goterror = 0;

void		 yyerror(const char*, ...);
int		 parse_portno(const char*);
void		 parse_conf(const char*);
char		*ensure_absolute_path(char*);
int		 check_block_code(int);
char		*check_block_fmt(char*);
int		 check_strip_no(int);
int		 check_prefork_num(int);
void		 advance_loc(void);

%}

/* for bison: */
/* %define parse.error verbose */

%union {
	char		*str;
	int		 num;
}

%token TIPV6 TPORT TPROTOCOLS TMIME TDEFAULT TTYPE
%token TCHROOT TUSER TSERVER TPREFORK
%token TLOCATION TCERT TKEY TROOT TCGI TLANG TLOG TINDEX TAUTO
%token TSTRIP TBLOCK TRETURN TENTRYPOINT TREQUIRE TCLIENT TCA
%token TERR

%token <str>	TSTRING
%token <num>	TNUM
%token <num>	TBOOL

%%

conf		: options vhosts ;

options		: /* empty */
		| options option
		;

option		: TCHROOT TSTRING	{ conf.chroot = $2; }
		| TIPV6 TBOOL		{ conf.ipv6 = $2; }
		| TMIME TSTRING TSTRING	{ add_mime(&conf.mime, $2, $3); }
		| TPORT TNUM		{ conf.port = $2; }
		| TPREFORK TNUM		{ conf.prefork = check_prefork_num($2); }
		| TPROTOCOLS TSTRING {
			if (tls_config_parse_protocols(&conf.protos, $2) == -1)
				yyerror("invalid protocols string \"%s\"", $2);
		}
		| TUSER TSTRING		{ conf.user = $2; }
		;

vhosts		: /* empty */
		| vhosts vhost
		;

vhost		: TSERVER TSTRING '{' servopts locations '}' {
			host->locations[0].match = xstrdup("*");
			host->domain = $2;

			if (strstr($2, "xn--") != NULL) {
				warnx("%s:%d \"%s\" looks like punycode: "
				    "you should use the decoded hostname.",
				    config_path, yylineno, $2);
			}

			if (host->cert == NULL || host->key == NULL ||
			    host->dir == NULL)
				yyerror("invalid vhost definition: %s", $2);

			if (++ihost == HOSTSLEN)
				errx(1, "too much vhosts defined");

			host++;
			loc = &host->locations[0];
			iloc = 0;
		}
		| error '}'		{ yyerror("error in server directive"); }
		;

servopts	: /* empty */
		| servopts servopt
		;

servopt		: TCERT TSTRING		{ host->cert = ensure_absolute_path($2); }
		| TCGI TSTRING		{
			/* drop the starting '/', if any */
			if (*$2 == '/')
				memmove($2, $2+1, strlen($2));
			host->cgi = $2;
		}
		| TENTRYPOINT TSTRING {
			if (host->entrypoint != NULL)
				yyerror("`entrypoint' specified more than once");
			while (*$2 == '/')
				memmove($2, $2+1, strlen($2));
			host->entrypoint = $2;
		}
		| TKEY TSTRING		{ host->key  = ensure_absolute_path($2); }
		| TROOT TSTRING		{ host->dir  = ensure_absolute_path($2); }
		| locopt
		;

locations	: /* empty */
		| locations location
		;

location	: TLOCATION { advance_loc(); } TSTRING '{' locopts '}'	{
			/* drop the starting '/' if any */
			if (*$3 == '/')
				memmove($3, $3+1, strlen($3));
			loc->match = $3;
		}
		| error '}'
		;

locopts		: /* empty */
		| locopts locopt
		;

locopt		: TAUTO TINDEX TBOOL	{ loc->auto_index = $3 ? 1 : -1; }
		| TBLOCK TRETURN TNUM TSTRING {
			if (loc->block_fmt != NULL)
				yyerror("`block' rule specified more than once");
			loc->block_fmt = check_block_fmt($4);
			loc->block_code = check_block_code($3);
		}
		| TBLOCK TRETURN TNUM {
			if (loc->block_fmt != NULL)
				yyerror("`block' rule specified more than once");
			loc->block_fmt = xstrdup("temporary failure");
			loc->block_code = check_block_code($3);
			if ($3 >= 30 && $3 < 40)
				yyerror("missing `meta' for block return %d", $3);
		}
		| TBLOCK {
			if (loc->block_fmt != NULL)
				yyerror("`block' rule specified more than once");
			loc->block_fmt = xstrdup("temporary failure");
			loc->block_code = 40;
		}
		| TDEFAULT TTYPE TSTRING {
			if (loc->default_mime != NULL)
				yyerror("`default type' specified more than once");
			loc->default_mime = $3;
		}
		| TINDEX TSTRING {
			if (loc->index != NULL)
				yyerror("`index' specified more than once");
			loc->index = $2;
		}
		| TLANG TSTRING {
			if (loc->lang != NULL)
				yyerror("`lang' specified more than once");
			loc->lang = $2;
		}
		| TLOG TBOOL	{ loc->disable_log = !$2; }
		| TREQUIRE TCLIENT TCA TSTRING {
			if (loc->reqca != NULL)
				yyerror("`require client ca' specified more than once");
			if (*$4 != '/')
				yyerror("path to certificate must be absolute: %s", $4);
			if ((loc->reqca = load_ca($4)) == NULL)
				yyerror("couldn't load ca cert: %s", $4);
			free($4);
		}
		| TSTRIP TNUM		{ loc->strip = check_strip_no($2); }
		;

%%

void
yyerror(const char *msg, ...)
{
	va_list ap;

	goterror = 1;

	va_start(ap, msg);
	fprintf(stderr, "%s:%d: ", config_path, yylineno);
	vfprintf(stderr, msg, ap);
	fprintf(stderr, "\n");
	va_end(ap);
}

int
parse_portno(const char *p)
{
	const char *errstr;
	int n;

	n = strtonum(p, 0, UINT16_MAX, &errstr);
	if (errstr != NULL)
		yyerror("port number is %s: %s", errstr, p);
	return n;
}

void
parse_conf(const char *path)
{
	host = &hosts[0];
	ihost = 0;
	loc = &hosts[0].locations[0];
	iloc = 0;

	config_path = path;
	if ((yyin = fopen(path, "r")) == NULL)
		fatal("cannot open config: %s: %s", path, strerror(errno));
	yyparse();
	fclose(yyin);

	if (goterror)
		exit(1);
}

char *
ensure_absolute_path(char *path)
{
	if (path == NULL || *path != '/')
		yyerror("not an absolute path");
	return path;
}

int
check_block_code(int n)
{
	if (n < 10 || n >= 70 || (n >= 20 && n <= 29))
		yyerror("invalid block code %d", n);
	return n;
}

char *
check_block_fmt(char *fmt)
{
	char *s;

	for (s = fmt; *s; ++s) {
		if (*s != '%')
			continue;
		switch (*++s) {
		case '%':
		case 'p':
		case 'q':
		case 'P':
		case 'N':
			break;
		default:
			yyerror("invalid format specifier %%%c", *s);
		}
	}

	return fmt;
}

int
check_strip_no(int n)
{
	if (n <= 0)
		yyerror("invalid strip number %d", n);
	return n;
}

int
check_prefork_num(int n)
{
	if (n <= 0 || n >= PROC_MAX)
		yyerror("invalid prefork number %d", n);
	return n;
}

void
advance_loc(void)
{
	if (++iloc == LOCLEN)
		errx(1, "too much location rules defined");
	loc++;
}

/* readynas_crypto - reimplementation of ReadyNAS firmware & addons encryption
 * Copyright (C) 2009 Henrik Nordstrom <henrik@henriknordstrom.net>
 *
 * This program is free software; you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation; either version 2 of the License, or
 * at your option) any later version.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License
 * along with this program; if not, write to the Free Software
 * Foundation, Inc., 59 Temple Place, Suite 330, Boston, MA 02111, USA.
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/types.h>
#include <sys/stat.h>
#include <fcntl.h>
#include <unistd.h>
#include <inttypes.h>
#include <arpa/inet.h>

#include "des.h"

void usage(const char *program)
{
	fprintf(stderr, "Usage: %s [-d|-e] [-f dev] [-k key]\n"
			"\t-d\tDecrypt (defult)\n"
			"\t-e\tEncrypt\n"
			"\t-k key\tSpecify key number or hex value\n"
			"\t\t0 Default key\n"
			"\t\t1 Secondary key\n"
			"\t\t2 Default key + XOR magic\n"
			"\t\t3 Secondary key + XOR magic\n"
			"\t\t48 hex digits key\n"
			"\t\t48 hex digits key X 8 hex digits XOR magic\n"
			, program);
}

void hwcp_scramble(char *buf, size_t size, uint32_t magic)
{
    size_t i;
    for (i = 0; i < size; i += 4) {
        *(uint32_t *)(buf + i) ^= htonl(i + magic);
    }

}

int main(int argc, char **argv)
{
	char inbuf[512];
	char outbuf[512];
	ssize_t n;
	int opt;
	const char *key = NULL;
	char des3_key[24];
	static const char readynas_key[2][24] = {
	    {
		    0x54,0x72,0x75,0x73,0x74,0x47,0x4F,0x44,0x49,0x6E,0x66,0x72,0x61,0x6E,0x74,0x57,0x69,0x6C,0x6C,0x47,0x6F,0x49,0x50,0x4F
	    },{
		    0x91,0xA8,0x46,0x8A,0x94,0xB9,0x2E,0x42,0xBE,0xD8,0x17,0xF7,0x27,0xB7,0x28,0xD2,0x96,0x35,0x11,0x2A,0x7C,0xE0,0x90,0x60
	    }
	};
	uint32_t magic = htonl(0xc1fcd408);
	int encrypt = 0;
	int scramble = 0;
	des3_context ctx;

	memcpy(des3_key, readynas_key[0], 24);

	memset(inbuf, 0, sizeof(inbuf));
	memset(outbuf, 0, sizeof(outbuf));

	while((opt = getopt(argc, argv, "dehk:")) != -1) {
	switch(opt) {
	case 'd':
		encrypt = 0;
		break;
	case 'e':
		encrypt = 1;
		break;
	case 'k':
		key = optarg;
		break;

	case 'h':
		usage(argv[0]);
		exit(0);
	}
	}

	if (optind < argc) {
		fprintf(stderr, "Unexpected argument '%s'\n", argv[optind]);
		usage(argv[0]);
		exit(1);
	}
	
	if (key) {
		switch(strlen(key)) {
		case 1:
		case 2:
		case 3:
		case 4:
		    {
			unsigned long keynum = strtoul(key, NULL, 0);
			memcpy(des3_key, readynas_key[keynum&1], 24);
			scramble = (keynum & 2);
		    }
		    break;
		case 6*8:
		case 6*8+1:
		case 6*8+1+8:
		    {
			char *p;
			char tmp[3];
			int i;
			memset(&tmp, 0, sizeof(tmp));
			p = (char *)&des3_key;
			scramble = 0;
			for (i = 0; key && i < 6 * 4; i++)
			{
			    tmp[0] = *key++;
			    tmp[1] = *key++;
			    *p++ = (char)strtoul(tmp, NULL, 16);
			}
			if (*key && *key++ == 'X') {
			    scramble = 1;
			    p = (char *)&magic;
			    for (i = 0; *key && i < 4; i++)
			    {
				tmp[0] = *key++;
				tmp[1] = *key++;
				*p++ = (char)strtoul(tmp, NULL, 16);
			    }
			}
		    }
		    break;
		default:
		    fprintf(stderr, "Unexpeted key argument. Should be either key number or 48 digits hex key or 48 digits hex key X xor magic 8 digits\n");
		    exit(1);
		    break;
		}
	}

	magic = ntohl(magic);

	des3_set_3keys(&ctx, (unsigned char *)des3_key);

	while((n = fread(inbuf, 1, sizeof(inbuf), stdin)) > 0) {
	    ssize_t done;
	    if (n & 7) memset(inbuf+n, 0, 8 - (n & 7));
	    n = (n + 7) & ~7;
	    if (encrypt) {
		if (scramble)
		    hwcp_scramble(inbuf, n, magic);
		for (done = 0; done < n; done += 8)
		   des3_encrypt(&ctx, (unsigned char *)inbuf + done, (unsigned char *)outbuf + done);
	    } else {
		for (done = 0; done < n; done += 8)
		   des3_decrypt(&ctx, (unsigned char *)inbuf + done, (unsigned char *)outbuf + done);
		if (scramble)
		    hwcp_scramble(outbuf, n, magic);
	    }
	    fwrite(outbuf, done, 1, stdout);
	}
	return 0;
}

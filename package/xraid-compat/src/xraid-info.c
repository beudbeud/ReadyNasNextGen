/*
 * xraid-info : analyse en LECTURE SEULE des disques X-RAID (ReadyNAS Duo v1,
 * RAIDiator-Sparc 4.x) pour la couche de compatibilité de Linux 6.18.
 *
 * Écrit d'après la description fonctionnelle du format (docs/XRAID.md) ;
 * aucun code d'Infrant/NETGEAR n'est repris. Le programme n'ouvre jamais un
 * disque en écriture.
 *
 *   xraid-info [--json] [--echantillons K] DISQUE...
 *        superbloc « WGao » (courant en N-4096, secours en N-4048, et leurs
 *        copies), rôle de chaque disque, sections, partitions du disque base,
 *        état (propre, synchronisation, disques), comparaison de K blocs de
 *        64 Kio par section aux mêmes LBA sur les deux disques, et verdict :
 *        rw (miroir assemblable), ro (lecture seule d'un disque) ou aucun.
 *        Sortie texte = lignes CLE='valeur' évaluables par sh (nas-raid).
 *   xraid-info verifier [--json] [--zone MIO] DISQUE_A DISQUE_B
 *        compare tout le contenu des sections des deux disques (lecture
 *        seule) ; code 0 = identiques, 1 = différences, 2 = erreurs.
 *   xraid-info smart [--json] DISQUE
 *        SMART par ATA PASS-THROUGH (SG_IO) : santé, secteurs réalloués,
 *        en attente, illisibles, heures (format de /var/run/smart.sdX).
 *
 * Entiers du superbloc : 32 bits gros-boutistes (écrits tels quels par le
 * SPARC). Table de partitions MBR : petit-boutiste, comme sur un PC.
 * Compilé pour SPARC v7 (Buildroot) : aucune instruction sdiv ni casa,
 * contrôlé par board/readynas-duo-v1/post-image.sh.
 */
#define _FILE_OFFSET_BITS 64
#include <errno.h>
#include <fcntl.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <sys/ioctl.h>
#include <scsi/sg.h>

typedef unsigned long long u64;

#define SB_LEN     0x24E0
#define WGAO       0x5747616Fu	/* configuration valide */
#define WGAN       0x5747616Eu	/* disque initialisé, prêt à être ajouté */
#define MD_MAGIC   0xa92b4efcu
#define MAXD       4		/* le Duo n'a que 2 baies ; 4 pour les NV */
#define MAXP       16
#define ECH        (64 * 1024)	/* bloc d'échantillonnage */

/* les 4 copies : courant, courant bis, secours, secours bis (N - x) */
static const unsigned COPIE[4] = { 4096, 4072, 4048, 4024 };
static const char *NOM_COPIE[4] = { "courant", "courant_bis", "secours", "secours_bis" };

static int json;

static unsigned be32(const unsigned char *p) { return (unsigned)p[0] << 24 | p[1] << 16 | p[2] << 8 | p[3]; }
static unsigned le32(const unsigned char *p) { return (unsigned)p[3] << 24 | p[2] << 16 | p[1] << 8 | p[0]; }

static const char *etat_nom(unsigned e)
{
	switch (e) {
	case 0: return "faulty";
	case 1: return "online";
	case 2: return "spare";
	case 8: return "ready";
	}
	return "inconnu";
}

struct disque {
	const char *chemin;
	int fd;
	u64 n;				/* secteurs natifs */
	unsigned char sb[4][SB_LEN];
	unsigned magic[4];
	int wgam;			/* marque « WGam » en N-2 */
	int md;				/* superbloc md trouvé (déjà migré) */
	unsigned char mbr[512];
	int mbr_ok;
	int canal;			/* index hwif d'après this_disk (1 = SATA 0) */
	int role;			/* 'b' base, 'm' miroir, 0 inconnu */
	int ref;			/* copie retenue (0 courant, 2 secours), -1 aucune */
};

struct section { unsigned debut, nb, fin, raid, init, dmap, init_mark, alive; };
struct part { int num; unsigned debut, nb, type; int sec; unsigned dec; };

static int lire(int fd, u64 octet, void *buf, size_t len)
{
	size_t f = 0;
	while (f < len) {
		ssize_t r = pread(fd, (char *)buf + f, len - f, (off_t)(octet + f));
		if (r < 0 && errno == EINTR)
			continue;
		if (r <= 0)
			return -1;
		f += (size_t)r;
	}
	return 0;
}

static void meurt(const char *fmt, ...)
{
	va_list a;
	va_start(a, fmt);
	fputs("xraid-info : ", stderr);
	vfprintf(stderr, fmt, a);
	fputc('\n', stderr);
	va_end(a);
	exit(2);
}

static void ouvrir(struct disque *d, const char *chemin)
{
	off_t t;
	memset(d, 0, sizeof(*d));
	/* le chemin est réinjecté dans du sh entre apostrophes : pas d'apostrophe */
	if (strchr(chemin, '\'') || strchr(chemin, '"') || strchr(chemin, '\\'))
		meurt("chemin refusé : %s", chemin);
	d->chemin = chemin;
	d->ref = -1;
	d->fd = open(chemin, O_RDONLY);
	if (d->fd < 0)
		meurt("%s : %s", chemin, strerror(errno));
	t = lseek(d->fd, 0, SEEK_END);
	if (t < 0)
		meurt("%s : taille illisible", chemin);
	d->n = (u64)t / 512;
}

/* superbloc md (1.0 en fin, 1.1 au début, 1.2 à 4 Kio, 0.90 en fin, 64 Kio) */
static void chercher_md(struct disque *d)
{
	unsigned char b[4];
	u64 taille = d->n * 512, pos[4];
	int i;
	pos[0] = 0;
	pos[1] = 4096;
	pos[2] = taille >= 8192 ? (taille - 8192) & ~(u64)4095 : 0;
	pos[3] = taille >= 65536 ? (taille & ~(u64)65535) - 65536 : 0;
	for (i = 0; i < 4; i++)
		if (lire(d->fd, pos[i], b, 4) == 0 && (le32(b) == MD_MAGIC || be32(b) == MD_MAGIC))
			d->md = 1;
}

static void lire_disque(struct disque *d)
{
	unsigned char b[4];
	int c;
	if (d->n < 0x200000)	/* < 1 Go : X-RAID ne se configure pas (§2) */
		return;
	for (c = 0; c < 4; c++) {
		if (lire(d->fd, (d->n - COPIE[c]) * 512, d->sb[c], SB_LEN) == 0)
			d->magic[c] = be32(d->sb[c]);
	}
	if (lire(d->fd, (d->n - 2) * 512, b, 4) == 0)
		d->wgam = memcmp(b, "WGam", 4) == 0;
	if (lire(d->fd, 0, d->mbr, 512) == 0)
		d->mbr_ok = d->mbr[510] == 0x55 && d->mbr[511] == 0xAA;
	chercher_md(d);
	if (d->magic[0] == WGAO)
		d->ref = 0;
	else if (d->magic[2] == WGAO)
		d->ref = 2;
	if (d->ref >= 0) {
		const unsigned char *t = d->sb[d->ref] + 0x1460;	/* this_disk */
		d->canal = t[2];
		d->role = t[1] ? 'b' : t[0] ? 'm' : 0;
	}
}

/* même configuration : tout sauf this_disk (0x0F80 .. 0x14DF) */
static int meme_sb(const unsigned char *a, const unsigned char *b)
{
	return memcmp(a, b, 0xF80) == 0 && memcmp(a + 0x14E0, b + 0x14E0, SB_LEN - 0x14E0) == 0;
}

/* ---------- sortie texte (CLE='valeur') ou JSON ---------- */
static int premier = 1;
static void cle_json(const char *k)	/* clés JSON en minuscules */
{
	printf("%s\"", premier ? "" : ",");
	for (; *k; k++)
		putchar(*k >= 'A' && *k <= 'Z' ? *k + 32 : *k);
	printf("\":");
}
static void cle_s(const char *k, const char *v)
{
	if (json)
		cle_json(k), printf("\"%s\"", v);
	else
		printf("XR_%s='%s'\n", k, v);
	premier = 0;
}
static void cle_n(const char *k, u64 v)
{
	if (json)
		cle_json(k), printf("%llu", v);
	else
		printf("XR_%s=%llu\n", k, v);
	premier = 0;
}

/* raisons : code court (pour sh) et texte (pour l'interface) */
#define MAXR 24
static const char *r_code[MAXR], *r_texte[MAXR];
static int nr;
static int bloque_rw, bloque_tout;
static void raison(int grave, const char *code, const char *texte)
{
	if (nr < MAXR) {
		r_code[nr] = code;
		r_texte[nr] = texte;
		nr++;
	}
	if (grave >= 1)
		bloque_rw = 1;
	if (grave >= 2)
		bloque_tout = 1;
}

/* partitions d'après un MBR ; EBR lus sur le disque de lecture */
static int lire_parts(const unsigned char *mbr, int fd, struct part *p)
{
	int i, n = 0;
	unsigned ext = 0;
	for (i = 0; i < 4; i++) {
		const unsigned char *e = mbr + 0x1BE + 16 * i;
		unsigned type = e[4], deb = le32(e + 8), nb = le32(e + 12);
		if (!type || !nb)
			continue;
		if (type == 0x05 || type == 0x0f || type == 0x85) {
			ext = deb;
			continue;
		}
		if (n < MAXP) {
			p[n].num = i + 1; p[n].debut = deb; p[n].nb = nb; p[n].type = type;
			n++;
		}
	}
	if (ext) {
		unsigned ebr = ext, num = 5, garde = 0;
		unsigned char b[512];
		while (ebr && garde++ < 64 && lire(fd, (u64)ebr * 512, b, 512) == 0
		       && b[510] == 0x55 && b[511] == 0xAA) {
			const unsigned char *e = b + 0x1BE;
			if (e[4] && le32(e + 12) && n < MAXP) {
				p[n].num = num; p[n].debut = ebr + le32(e + 8);
				p[n].nb = le32(e + 12); p[n].type = e[4];
				n++;
			}
			num++;
			ebr = e[16 + 4] ? ext + le32(e + 16 + 8) : 0;
		}
	}
	return n;
}

/* compare k blocs de 64 Kio par section ; nombre d'écarts, -1 si erreur */
static int echantillonner(int fa, int fb, const struct section *s, int ns, int k)
{
	static unsigned char a[ECH], b[ECH];
	int i, j, diff = 0;
	for (i = 0; i < ns; i++) {
		u64 lg = s[i].fin - s[i].debut, pas;
		if (lg < ECH / 512 || k < 1)
			continue;
		pas = k > 1 ? (lg - ECH / 512) / (u64)(k - 1) : 0;
		for (j = 0; j < k; j++) {
			u64 lba = s[i].debut + pas * (u64)j;
			if (lire(fa, lba * 512, a, ECH) || lire(fb, lba * 512, b, ECH))
				return -1;
			diff += memcmp(a, b, ECH) != 0;
		}
	}
	return diff;
}

/* ---------- analyse ---------- */
static int analyser(int argc, char **argv, int k)
{
	static struct disque D[MAXD];
	struct section S[7];
	struct part P[MAXP];
	int nd = argc, i, j, ref = -1, ns = 0, np = 0, base = -1, miroir = -1, lect = -1;
	int diffsb = 0, diff = -2;
	const unsigned char *sb;
	unsigned v, nr_disks, raid_disks, fake, propre, nb_lun, ver[3];
	char buf[64];

	if (nd < 1 || nd > MAXD)
		meurt("1 à %d disques", MAXD);
	for (i = 0; i < nd; i++) {
		ouvrir(&D[i], argv[i]);
		lire_disque(&D[i]);
	}
	/* superbloc de référence : identique sur la majorité, sinon le plus récent */
	for (i = 0; i < nd; i++) {
		if (D[i].ref < 0)
			continue;
		if (ref < 0) { ref = i; continue; }
		if (!meme_sb(D[i].sb[D[i].ref], D[ref].sb[D[ref].ref])) {
			diffsb = 1;
			if (be32(D[i].sb[D[i].ref] + 0x18) > be32(D[ref].sb[D[ref].ref] + 0x18))
				ref = i;
		}
	}

	if (json)
		printf("{");
	if (ref < 0) {
		cle_s("MODE", "aucun");
		for (i = 0; i < nd; i++)
			if (D[i].md) { cle_s("MD", "1"); break; }
		if (json) printf(",\"raisons\":[{\"code\":\"pas_de_xraid\",\"texte\":\"aucun superbloc X-RAID (WGao)\"}]}\n");
		else printf("XR_RAISONS='pas_de_xraid'\n");
		return 0;
	}
	sb = D[ref].sb[D[ref].ref];
	ver[0] = be32(sb + 4); ver[1] = be32(sb + 8); ver[2] = be32(sb + 12);
	v = be32(sb + 0x20);
	nr_disks = be32(sb + 0x24);
	raid_disks = be32(sb + 0x28);
	fake = sb[0x33];
	propre = be32(sb + 0x84) & 1;
	nb_lun = be32(sb + 0x100);

	/* contrôles */
	if (ver[0] != 0 || ver[1] != 1 || ver[2] != 0)
		raison(2, "version", "version de superbloc inconnue (attendu 0.1.0)");
	if (be32(sb + 0x1C) != 1)
		raison(2, "level", "champ level différent de 1");
	if (D[ref].ref != 0)
		raison(1, "superbloc_secours", "superbloc courant absent : lecture du secours");
	if (diffsb)
		raison(1, "superblocs_differents", "les superblocs des disques diffèrent");
	if (!propre)
		raison(1, "arret_brutal", "superbloc marqué « arrêt non propre » (clean shutdown à 0)");
	if (nr_disks != 2 || raid_disks != 2 || fake)
		raison(1, "pas_2_disques", "configuration à un disque (miroir fictif) ou à plus de 2 disques");
	if (v == 0 || v > D[ref].n - 4096)
		raison(2, "taille", "taille visible V incohérente");
	if (nb_lun < 1 || nb_lun > 7)
		raison(2, "sections", "nombre de sections incohérent");

	/* sections, bornées à la zone visible V (jamais la zone protégée) */
	for (i = 0; i < 7; i++) {
		const unsigned char *e = sb + 0x800 + 32 * i;
		if (!e[6])
			continue;
		S[ns].alive = 1;
		S[ns].raid = e[5];
		/* +4 disques porteurs (bits 0 et 1 : dmap du pilote), +7 « initialized »
		 * (1 = miroir synchronisé). +8 n'est PAS un point de reprise : il reste
		 * non nul sur un volume sain (initialized=1, redundant sous RAIDiator). */
		S[ns].dmap = e[4];
		S[ns].init = e[7];
		S[ns].init_mark = be32(e + 8);
		S[ns].debut = be32(e + 0x10);
		S[ns].nb = be32(e + 0x18);
		S[ns].fin = S[ns].debut + S[ns].nb;
		if (S[ns].fin > v || S[ns].fin < S[ns].debut)
			S[ns].fin = v;
		if (S[ns].raid != 1)
			raison(1, "pas_raid1", "section qui n'est pas un miroir (RAID 4)");
		if (S[ns].init != 1)
			raison(1, "synchro_en_cours", "synchronisation X-RAID inachevée (section non initialisée)");
		if ((S[ns].dmap & 3) != 3)
			raison(1, "section_degradee", "section portée par un seul disque (dmap)");
		if (S[ns].debut >= S[ns].fin)
			raison(2, "sections", "section vide ou hors zone visible");
		ns++;
	}
	for (i = 1; i < ns; i++)
		if (S[i].debut < S[i - 1].fin)
			raison(2, "sections", "sections qui se chevauchent");

	/* disques : rôle, état dans la table de référence */
	for (i = 0; i < nd; i++) {
		if (D[i].ref < 0)
			continue;
		/* tailles différentes admises : mêmes LBA, bornées à V (le plus petit) */
		if (v > D[i].n - 4096)
			raison(2, "taille", "taille visible V au-delà d'un disque");
		if (D[i].canal < 1 || D[i].canal > 11) {
			raison(1, "role_inconnu", "this_disk illisible");
			continue;
		}
		if (D[i].role == 'b') {
			if (base >= 0) raison(2, "deux_bases", "deux disques se disent « base »");
			base = i;
		} else if (D[i].role == 'm') {
			if (miroir >= 0) raison(2, "deux_miroirs", "deux disques se disent « miroir »");
			miroir = i;
		}
	}
	for (i = 0; i < nd; i++)
		for (j = i + 1; j < nd; j++)
			if (D[i].ref >= 0 && D[j].ref >= 0 && D[i].canal == D[j].canal)
				raison(2, "meme_canal", "deux disques déclarent le même canal");
	if (base < 0 || miroir < 0) {
		raison(1, "disque_manquant", "un des deux disques X-RAID est absent : lecture seule");
	}
	for (i = 0; i < nd; i++) {
		unsigned et;
		if (D[i].ref < 0)
			continue;
		et = be32(sb + 0x200 + 128 * D[i].canal + 0x10);
		if (et != 1)
			raison(1, "disque_pas_online", "un disque n'est pas « online » (en reconstruction, de secours ou en panne)");
	}
	/* disque lu en lecture seule : base online, sinon miroir online */
	for (i = 0; i < nd; i++)
		if (i == base && be32(sb + 0x200 + 128 * D[i].canal + 0x10) == 1)
			lect = i;
	if (lect < 0)
		for (i = 0; i < nd; i++)
			if (i == miroir && be32(sb + 0x200 + 128 * D[i].canal + 0x10) == 1)
				lect = i;
	if (lect < 0)
		raison(2, "aucun_disque_lisible", "aucun disque « online » à lire");

	/* partitions : MBR du disque base, sinon p_table recopiée dans le superbloc */
	if (lect >= 0) {
		unsigned char mbr[512];
		memset(mbr, 0, sizeof(mbr));
		if (base >= 0 && D[base].mbr_ok)
			memcpy(mbr, D[base].mbr, 512);
		else if (base >= 0 || miroir >= 0) {
			/* entrée du disque base dans la table : celle qui a b_drive */
			for (i = 1; i < 12; i++)
				if (sb[0x200 + 128 * i + 1]) {
					memcpy(mbr + 0x1C0, sb + 0x200 + 128 * i + 0x18, 64);
					break;
				}
			raison(1, "mbr_reconstitue", "MBR du disque base absent : table reprise du superbloc");
		}
		if (mbr[510] == 0x55 && mbr[511] == 0xAA)
			np = lire_parts(mbr, D[lect].fd, P);
		if (!np)
			raison(2, "pas_de_partition", "aucune partition trouvée sur le disque base");
	}
	for (i = 0; i < np; i++) {
		P[i].sec = -1;
		for (j = 0; j < ns; j++)
			if (P[i].debut >= S[j].debut && (u64)P[i].debut + P[i].nb <= S[j].fin) {
				P[i].sec = j;
				P[i].dec = P[i].debut - S[j].debut;
			}
		if (P[i].sec < 0)
			raison(1, "partition_hors_section", "une partition déborde des sections (ou de la zone visible)");
	}

	/* échantillonnage aux mêmes LBA */
	if (base >= 0 && miroir >= 0 && k > 0 && !bloque_tout) {
		diff = echantillonner(D[base].fd, D[miroir].fd, S, ns, k);
		if (diff < 0)
			raison(1, "erreur_lecture", "erreur de lecture pendant l'échantillonnage");
		else if (diff > 0)
			raison(1, "miroir_different", "des blocs diffèrent entre les deux disques aux mêmes LBA");
	}

	cle_s("MODE", bloque_tout ? "aucun" : bloque_rw ? "ro" : "rw");
	for (i = 0; i < nd; i++)
		if (D[i].md) { cle_s("MD", "1"); break; }
	cle_n("N", D[ref].n);
	cle_n("V", v);
	cle_n("ZONE_PROTEGEE", v);
	snprintf(buf, sizeof(buf), "%u.%u.%u", ver[0], ver[1], ver[2]);
	cle_s("VERSION", buf);
	snprintf(buf, sizeof(buf), "%08x", be32(sb + 0x14));
	cle_s("ID", buf);
	cle_n("CTIME", be32(sb + 0x18));
	cle_n("PROPRE", propre);
	cle_n("NB_DISQUES", nr_disks);
	cle_s("BASE", base >= 0 ? D[base].chemin : "");
	cle_s("MIROIR", miroir >= 0 ? D[miroir].chemin : "");
	cle_s("LECTURE", lect >= 0 ? D[lect].chemin : "");
	cle_n("ECHANTILLONS", (u64)(diff == -2 ? 0 : k));
	if (diff >= 0)
		cle_n("DIFFERENCES", (u64)diff);

	/* disques */
	if (json) printf(",\"disques\":[");
	else printf("XR_NB_DISQUES_LUS=%d\n", nd);
	for (i = 0; i < nd; i++) {
		const char *role = D[i].role == 'b' ? "base" : D[i].role == 'm' ? "miroir" : "";
		const char *et = D[i].ref >= 0 ? etat_nom(be32(sb + 0x200 + 128 * D[i].canal + 0x10)) : "";
		char copies[64] = "";
		int c;
		for (c = 0; c < 4; c++)
			if (D[i].magic[c] == WGAO || D[i].magic[c] == WGAN) {
				strcat(copies, *copies ? "," : "");
				strcat(copies, NOM_COPIE[c]);
			}
		if (json)
			printf("%s{\"chemin\":\"%s\",\"secteurs\":%llu,\"role\":\"%s\",\"canal\":%d,\"etat\":\"%s\",\"copies\":\"%s\",\"wgam\":%d,\"mbr\":%d,\"md\":%d}",
			       i ? "," : "", D[i].chemin, D[i].n, role, D[i].canal - 1, et, copies, D[i].wgam, D[i].mbr_ok, D[i].md);
		else
			printf("XR_D%d='%s %llu %s %d %s %s %d %d %d'\n", i, D[i].chemin, D[i].n, *role ? role : "-",
			       D[i].canal - 1, *et ? et : "-", *copies ? copies : "-", D[i].wgam, D[i].mbr_ok, D[i].md);
	}
	/* sections : début, secteurs utilisables (bornés à V), niveau, initialisée */
	if (json) printf("],\"sections\":[");
	else printf("XR_NB_SECTIONS=%d\n", ns);
	for (i = 0; i < ns; i++) {
		if (json)
			printf("%s{\"debut\":%u,\"secteurs\":%u,\"secteurs_declares\":%u,\"raid\":%u,\"init\":%u,\"dmap\":%u,\"init_mark\":%u}",
			       i ? "," : "", S[i].debut, S[i].fin - S[i].debut, S[i].nb, S[i].raid, S[i].init, S[i].dmap, S[i].init_mark);
		else
			printf("XR_S%d='%u %u %u %u'\n", i, S[i].debut, S[i].fin - S[i].debut, S[i].raid, S[i].init);
	}
	/* partitions : numéro, début, taille, type, section, décalage dans la section */
	if (json) printf("],\"partitions\":[");
	else printf("XR_NB_PARTS=%d\n", np);
	for (i = 0; i < np; i++) {
		if (json)
			printf("%s{\"num\":%d,\"debut\":%u,\"secteurs\":%u,\"type\":\"%02x\",\"section\":%d,\"decalage\":%u}",
			       i ? "," : "", P[i].num, P[i].debut, P[i].nb, P[i].type, P[i].sec, P[i].dec);
		else
			printf("XR_P%d='%d %u %u %02x %d %u'\n", i, P[i].num, P[i].debut, P[i].nb, P[i].type, P[i].sec, P[i].dec);
	}
	if (json) {
		printf("],\"raisons\":[");
		for (i = 0; i < nr; i++)
			printf("%s{\"code\":\"%s\",\"texte\":\"%s\"}", i ? "," : "", r_code[i], r_texte[i]);
		printf("]}\n");
	} else {
		printf("XR_RAISONS='");
		for (i = 0; i < nr; i++)
			printf("%s%s", i ? " " : "", r_code[i]);
		printf("'\n");
		for (i = 0; i < nr; i++)
			printf("# %s : %s\n", r_code[i], r_texte[i]);
	}
	return 0;
}

/* ---------- vérification complète du miroir (lecture seule) ---------- */
static int verifier(int argc, char **argv, unsigned zone_mio)
{
	static struct disque A, B;
	struct section S[7];
	const unsigned char *sb;
	unsigned char *a, *b;
	unsigned v;
	int i, ns = 0, erreurs = 0;
	u64 total = 0, fait = 0, zones = 0, premiere = 0;
	const unsigned bloc = 1024 * 1024;
	unsigned pct = 101;

	if (argc != 2)
		meurt("verifier : deux disques attendus");
	ouvrir(&A, argv[0]);
	ouvrir(&B, argv[1]);
	lire_disque(&A);
	lire_disque(&B);
	if (A.ref < 0 && B.ref < 0)
		meurt("aucun superbloc X-RAID");
	sb = A.ref >= 0 ? A.sb[A.ref] : B.sb[B.ref];
	v = be32(sb + 0x20);
	for (i = 0; i < 7; i++) {
		const unsigned char *e = sb + 0x800 + 32 * i;
		if (!e[6])
			continue;
		S[ns].debut = be32(e + 0x10);
		S[ns].fin = S[ns].debut + be32(e + 0x18);
		if (S[ns].fin > v || S[ns].fin < S[ns].debut)
			S[ns].fin = v;
		if (S[ns].fin > S[ns].debut)
			total += S[ns].fin - S[ns].debut, ns++;
	}
	if (!zone_mio)
		zone_mio = 64;
	a = malloc(bloc);
	b = malloc(bloc);
	if (!a || !b)
		meurt("mémoire");
	for (i = 0; i < ns; i++) {
		u64 lba = S[i].debut, zone_diff = (u64)-1;
		while (lba < S[i].fin) {
			u64 nb = S[i].fin - lba;
			size_t len;
			int essai, d = 1;
			if (nb > bloc / 512)
				nb = bloc / 512;
			len = (size_t)nb * 512;
			/* un écart peut venir d'une écriture en cours : relire 3 fois */
			for (essai = 0; essai < 3 && d; essai++) {
				if (essai)
					sleep(1);
				if (lire(A.fd, lba * 512, a, len) || lire(B.fd, lba * 512, b, len)) {
					fprintf(stderr, "erreur de lecture vers le LBA %llu\n", lba);
					erreurs++;
					d = 0;
					break;
				}
				d = memcmp(a, b, len) != 0;
			}
			if (d) {
				u64 z = (lba - S[i].debut) / ((u64)zone_mio * 2048);
				if (z != zone_diff) {
					zone_diff = z;
					if (!zones)
						premiere = lba;
					zones++;
					printf("# difference section %d zone %llu (LBA %llu)\n", i, z,
					       S[i].debut + z * (u64)zone_mio * 2048);
				}
			}
			lba += nb;
			fait += nb;
			if (fait * 100 / total != pct) {
				pct = (unsigned)(fait * 100 / total);
				fprintf(stderr, "progression %u%%\n", pct);
			}
		}
	}
	premier = 1;
	if (json) printf("{");
	cle_s("RESULTAT", erreurs ? "erreurs" : zones ? "differences" : "identiques");
	cle_n("SECTEURS_COMPARES", fait);
	cle_n("ZONES_DIFFERENTES", zones);
	cle_n("ZONE_MIO", zone_mio);
	cle_n("PREMIERE_DIFFERENCE", premiere);
	cle_n("ERREURS_LECTURE", (u64)erreurs);
	if (json) printf("}\n");
	return erreurs ? 2 : zones ? 1 : 0;
}

/* ---------- SMART par ATA PASS-THROUGH (16), sans smartctl ---------- */
static int ata16(int fd, unsigned char *cdb, unsigned char *data, int lg, unsigned char *sense)
{
	sg_io_hdr_t h;
	memset(&h, 0, sizeof(h));
	memset(sense, 0, 32);
	h.interface_id = 'S';
	h.cmd_len = 16;
	h.cmdp = cdb;
	h.dxfer_direction = lg ? SG_DXFER_FROM_DEV : SG_DXFER_NONE;
	h.dxferp = data;
	h.dxfer_len = (unsigned)lg;
	h.sbp = sense;
	h.mx_sb_len = 32;
	h.timeout = 15000;
	return ioctl(fd, SG_IO, &h);
}

static int smart(const char *chemin)
{
	unsigned char cdb[16], data[512], sense[32], sum = 0, mid = 0, high = 0;
	unsigned long long realloc = 0, pending = 0, uncorr = 0, heures = 0;
	const char *sante = "";
	int fd = open(chemin, O_RDONLY | O_NONBLOCK), i;
	if (fd < 0)
		meurt("%s : %s", chemin, strerror(errno));
	/* SMART READ DATA : PIO data-in, 1 secteur */
	memset(cdb, 0, 16);
	cdb[0] = 0x85; cdb[1] = 4 << 1; cdb[2] = 0x0e;
	cdb[4] = 0xD0; cdb[6] = 1; cdb[10] = 0x4f; cdb[12] = 0xc2; cdb[14] = 0xB0;
	if (ata16(fd, cdb, data, 512, sense) < 0)
		meurt("%s : SG_IO refusé (%s)", chemin, strerror(errno));
	for (i = 0; i < 512; i++)
		sum += data[i];
	if (sum)
		meurt("%s : données SMART illisibles (somme de contrôle)", chemin);
	for (i = 0; i < 30; i++) {
		const unsigned char *e = data + 2 + 12 * i;
		u64 brut = (u64)e[5] | (u64)e[6] << 8 | (u64)e[7] << 16 | (u64)e[8] << 24;
		switch (e[0]) {
		case 5: realloc = brut; break;
		case 9: heures = brut; break;
		case 197: pending = brut; break;
		case 198: uncorr = brut; break;
		}
	}
	/* SMART RETURN STATUS : non-data, CK_COND pour relire LBA mid/high */
	memset(cdb, 0, 16);
	cdb[0] = 0x85; cdb[1] = 3 << 1; cdb[2] = 0x20;
	cdb[4] = 0xDA; cdb[10] = 0x4f; cdb[12] = 0xc2; cdb[14] = 0xB0;
	if (ata16(fd, cdb, NULL, 0, sense) == 0) {
		if ((sense[0] & 0x7f) == 0x72 && sense[8] == 0x09) {	/* descripteur ATA */
			mid = sense[8 + 9]; high = sense[8 + 11];
		} else if ((sense[0] & 0x7f) == 0x70) {			/* format fixe (libata) */
			mid = sense[10]; high = sense[11];
		}
		if (mid == 0x4f && high == 0xc2)
			sante = "PASSED";
		else if (mid == 0xf4 && high == 0x2c)
			sante = "FAILED";
	}
	close(fd);
	if (json)
		printf("{\"health\":\"%s\",\"realloc\":%llu,\"pending\":%llu,\"uncorr\":%llu,\"hours\":%llu}\n",
		       sante, realloc, pending, uncorr, heures);
	else	/* même format que /var/run/smart.sdX (diet-hwmon) */
		printf("health=%s realloc=%llu pending=%llu uncorr=%llu hours=%llu\n",
		       sante, realloc, pending, uncorr, heures);
	return 0;
}

int main(int argc, char **argv)
{
	int k = 0;
	unsigned zone = 0;
	const char *cmd = "analyser";

	argc--, argv++;
	if (argc && (!strcmp(argv[0], "verifier") || !strcmp(argv[0], "smart")))
		cmd = argv[0], argc--, argv++;
	while (argc && argv[0][0] == '-' && argv[0][1] == '-') {
		if (!strcmp(argv[0], "--json"))
			json = 1;
		else if (!strcmp(argv[0], "--echantillons") && argc > 1)
			k = atoi(argv[1]), argc--, argv++;
		else if (!strcmp(argv[0], "--zone") && argc > 1)
			zone = (unsigned)atoi(argv[1]), argc--, argv++;
		else
			meurt("option inconnue %s (voir l'en-tête de xraid-info.c)", argv[0]);
		argc--, argv++;
	}
	if (k < 0 || k > 100000)
		meurt("--echantillons : 0..100000");
	if (!strcmp(cmd, "verifier"))
		return verifier(argc, argv, zone);
	if (!strcmp(cmd, "smart")) {
		if (argc != 1)
			meurt("smart : un disque");
		return smart(argv[0]);
	}
	return analyser(argc, argv, k);
}

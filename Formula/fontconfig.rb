class Fontconfig < Formula
  desc "XML-based font configuration API for X Windows"
  homepage "https://wiki.freedesktop.org/www/Software/fontconfig/"
  url "https://www.freedesktop.org/software/fontconfig/release/fontconfig-2.11.1.tar.bz2"
  sha256 "dc62447533bca844463a3c3fd4083b57c90f18a70506e7a9f4936b5a1e516a99"
  revision 2

  # The bottle tooling is too lenient and thinks fontconfig
  # is relocatable, but it has hardcoded paths in the executables.
  bottle do
    cellar :any
    sha256 "6a2492b8e02a1b17cb2b2090917a5957934a25d24b13fe33cc213f07c7119955" => :el_capitan
    sha256 "23574b814f3cd34dbbc00151038e50eee7d7db2cb0db9a581a06155a30b31b91" => :yosemite
    sha256 "36104e396d373ff8c593ee61053534007f4436bf5c2d9ebbf29843aaccc51064" => :mavericks
    sha256 "c2cb4de712366ac795ec547eb8c000595d9c95c6ea15584fd3fad4c691014d2f" => :x86_64_linux
  end

  pour_bottle? do
    reason "The bottle needs to be installed into /usr/local."
    # c.f. the identical hack in lua
    # https://github.com/Homebrew/homebrew/issues/47173
    satisfy { HOMEBREW_PREFIX.to_s == "/usr/local" }
  end

  keg_only :provided_pre_mountain_lion

  option :universal

  depends_on "pkg-config" => :build
  depends_on "freetype"
  depends_on "bzip2" => :recommended unless OS.mac?
  depends_on "expat" unless OS.mac?

  # Reverts commit https://cgit.freedesktop.org/fontconfig/commit/?id=7a6622f25cdfab5ab775324bef1833b67109801b,
  # which breaks caching font directories containing subdirectories
  # See: https://github.com/Homebrew/homebrew/issues/28111
  # Reported upstream, message to mailing list is waiting moderation.
  patch :DATA

  def install
    ENV.universal_binary if build.universal?
    system "./configure", "--disable-dependency-tracking",
                          "--disable-silent-rules",
                          "--enable-static",
                          "--with-add-fonts=/System/Library/Fonts,/Library/Fonts,~/Library/Fonts",
                          "--prefix=#{prefix}",
                          "--localstatedir=#{var}",
                          "--sysconfdir=#{etc}"
    system "make", "install", "RUN_FC_CACHE_TEST=false"
  end

  def post_install
    ohai "Regenerating font cache, this may take a while"
    system "#{bin}/fc-cache", "-frv"
  end

  test do
    system "#{bin}/fc-list"
  end
end

__END__
diff --git a/fc-cache/fc-cache.c b/fc-cache/fc-cache.c
index 99e0e9f..bf3b6b4 100644
--- a/fc-cache/fc-cache.c
+++ b/fc-cache/fc-cache.c
@@ -187,13 +187,8 @@ scanDirs (FcStrList *list, FcConfig *config, FcBool force, FcBool really_force,
 	
 	if (!cache)
 	{
-	    if (!recursive)
-		cache = FcDirCacheRescan (dir, config);
-	    else
-	    {
-		(*changed)++;
-		cache = FcDirCacheRead (dir, FcTrue, config);
-	    }
+	    (*changed)++;
+	    cache = FcDirCacheRead (dir, FcTrue, config);
 	    if (!cache)
 	    {
 		fprintf (stderr, "%s: error scanning\n", dir);
@@ -391,7 +386,6 @@ main (int argc, char **argv)
 	ret += scanDirs (list, config, FcTrue, really_force, verbose, FcFalse, &changed, NULL);
 	FcStrListDone (list);
     }
-    FcStrSetDestroy (updateDirs);
 
     /*
      * Try to create CACHEDIR.TAG anyway.
diff --git a/fontconfig/fontconfig.h b/fontconfig/fontconfig.h
index 2258251..d0b4e9e 100644
--- a/fontconfig/fontconfig.h
+++ b/fontconfig/fontconfig.h
@@ -541,9 +541,6 @@ FcDirSave (FcFontSet *set, FcStrSet *dirs, const FcChar8 *dir);
 
 FcPublic FcCache *
 FcDirCacheLoad (const FcChar8 *dir, FcConfig *config, FcChar8 **cache_file);
-
-FcPublic FcCache *
-FcDirCacheRescan (const FcChar8 *dir, FcConfig *config);
     
 FcPublic FcCache *
 FcDirCacheRead (const FcChar8 *dir, FcBool force, FcConfig *config);
diff --git a/src/fccache.c b/src/fccache.c
index 5173e0b..10eacff 100644
--- a/src/fccache.c
+++ b/src/fccache.c
@@ -828,19 +828,6 @@ bail1:
     return NULL;
 }
 
-FcCache *
-FcDirCacheRebuild (FcCache *cache, struct stat *dir_stat, FcStrSet *dirs)
-{
-    FcCache *new;
-    FcFontSet *set = FcFontSetDeserialize (FcCacheSet (cache));
-    const FcChar8 *dir = FcCacheDir (cache);
-
-    new = FcDirCacheBuild (set, dir, dir_stat, dirs);
-    FcFontSetDestroy (set);
-
-    return new;
-}
-
 /* write serialized state to the cache file */
 FcBool
 FcDirCacheWrite (FcCache *cache, FcConfig *config)
diff --git a/src/fcdir.c b/src/fcdir.c
index 3bcd0b8..b040a28 100644
--- a/src/fcdir.c
+++ b/src/fcdir.c
@@ -130,12 +130,7 @@ FcFileScanConfig (FcFontSet	*set,
     if (FcFileIsDir (file))
 	return FcStrSetAdd (dirs, file);
     else
-    {
-	if (set)
-	    return FcFileScanFontConfig (set, blanks, file, config);
-	else
-	    return FcTrue;
-    }
+	return FcFileScanFontConfig (set, blanks, file, config);
 }
 
 FcBool
@@ -311,45 +306,6 @@ FcDirCacheScan (const FcChar8 *dir, FcConfig *config)
     return cache;
 }
 
-FcCache *
-FcDirCacheRescan (const FcChar8 *dir, FcConfig *config)
-{
-    FcCache *cache = FcDirCacheLoad (dir, config, NULL);
-    FcCache *new = NULL;
-    struct stat dir_stat;
-    FcStrSet *dirs;
-
-    if (!cache)
-	return NULL;
-    if (FcStatChecksum (dir, &dir_stat) < 0)
-	goto bail;
-    dirs = FcStrSetCreate ();
-    if (!dirs)
-	goto bail;
-
-    /*
-     * Scan the dir
-     */
-    if (!FcDirScanConfig (NULL, dirs, NULL, dir, FcTrue, config))
-	goto bail1;
-    /*
-     * Rebuild the cache object
-     */
-    new = FcDirCacheRebuild (cache, &dir_stat, dirs);
-    if (!new)
-	goto bail1;
-    FcDirCacheUnload (cache);
-    /*
-     * Write out the cache file, ignoring any troubles
-     */
-    FcDirCacheWrite (new, config);
-
-bail1:
-    FcStrSetDestroy (dirs);
-bail:
-    return new;
-}
-
 /*
  * Read (or construct) the cache for a directory
  */
diff --git a/src/fcfs.c b/src/fcfs.c
index 21c6c7c..941abba 100644
--- a/src/fcfs.c
+++ b/src/fcfs.c
@@ -122,28 +122,6 @@ FcFontSetSerialize (FcSerialize *serialize, const FcFontSet * s)
 
     return s_serialize;
 }
-
-FcFontSet *
-FcFontSetDeserialize (const FcFontSet *set)
-{
-    int i;
-    FcFontSet *new = FcFontSetCreate ();
-
-    if (!new)
-	return NULL;
-    for (i = 0; i < set->nfont; i++)
-    {
-	if (!FcFontSetAdd (new, FcPatternDuplicate (FcFontSetFont (set, i))))
-	    goto bail;
-    }
-
-    return new;
-bail:
-    FcFontSetDestroy (new);
-
-    return NULL;
-}
-
 #define __fcfs__
 #include "fcaliastail.h"
 #undef __fcfs__
diff --git a/src/fcint.h b/src/fcint.h
index cdf2dab..362ea6f 100644
--- a/src/fcint.h
+++ b/src/fcint.h
@@ -567,9 +567,6 @@ FcDirCacheScan (const FcChar8 *dir, FcConfig *config);
 FcPrivate FcCache *
 FcDirCacheBuild (FcFontSet *set, const FcChar8 *dir, struct stat *dir_stat, FcStrSet *dirs);
 
-FcPrivate FcCache *
-FcDirCacheRebuild (FcCache *cache, struct stat *dir_stat, FcStrSet *dirs);
-
 FcPrivate FcBool
 FcDirCacheWrite (FcCache *cache, FcConfig *config);
 
@@ -841,9 +838,6 @@ FcFontSetSerializeAlloc (FcSerialize *serialize, const FcFontSet *s);
 FcPrivate FcFontSet *
 FcFontSetSerialize (FcSerialize *serialize, const FcFontSet * s);
 
-FcPrivate FcFontSet *
-FcFontSetDeserialize (const FcFontSet *set);
-
 /* fchash.c */
 FcPrivate FcChar8 *
 FcHashGetSHA256Digest (const FcChar8 *input_strings,
diff --git a/src/fcpat.c b/src/fcpat.c
index 986cca3..0614ac2 100644
--- a/src/fcpat.c
+++ b/src/fcpat.c
@@ -33,7 +33,6 @@ FcPatternCreate (void)
     p = (FcPattern *) malloc (sizeof (FcPattern));
     if (!p)
 	return 0;
-    memset (p, 0, sizeof (FcPattern));
     p->num = 0;
     p->size = 0;
     p->elts_offset = FcPtrToOffset (p, NULL);
@@ -1311,7 +1310,6 @@ FcValueListSerialize (FcSerialize *serialize, const FcValueList *vl)
     }
     return head_serialized;
 }
-
 #define __fcpat__
 #include "fcaliastail.h"
 #include "fcftaliastail.h"

import spdx
import collections

DepRecipe = collections.namedtuple("DepRecipe", ("doc", "doc_sha1", "recipe"))
DepSource = collections.namedtuple("DepSource", ("doc", "doc_sha1", "recipe", "file"))


def get_recipe_spdxid(d):
    return "SPDXRef-%s-%s" % ("Recipe", d.getVar("PN"))


def get_package_spdxid(pkg):
    return "SPDXRef-Package-%s" % pkg


def get_source_file_spdxid(d, idx):
    return "SPDXRef-SourceFile-%s-%d" % (d.getVar("PN"), idx)


def get_packaged_file_spdxid(pkg, idx):
    return "SPDXRef-PackagedFile-%s-%d" % (pkg, idx)


def get_image_spdxid(img):
    return "SPDXRef-Image-%s" % img

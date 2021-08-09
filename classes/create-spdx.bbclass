inherit cve-data

DEPLOY_DIR_SPDX ??= "${DEPLOY_DIR}/spdx/${MACHINE}"

SPDXDIR ??= "${WORKDIR}/spdx"
SPDXDEPLOY = "${SPDXDIR}/deploy"
SPDXWORK = "${SPDXDIR}/work"

SPDX_INCLUDE_SOURCES ??= "0"
SPDX_INCLUDE_PACKAGED ??= "0"
SPDX_ARCHIVE_SOURCES ??= "0"
SPDX_ARCHIVE_PACKAGED ??= "0"

SPDX_UUID_NAMESPACE ??= "sbom.openembedded.org"
SPDX_NAMESPACE_PREFIX ??= "http://spdx.org/spdxdoc"

do_image_complete[depends] = "virtual/kernel:do_create_spdx"

def get_doc_namespace(d, doc):
    import uuid
    namespace_uuid = uuid.uuid5(uuid.NAMESPACE_DNS, d.getVar("SPDX_UUID_NAMESPACE"))
    return "%s/%s-%s" % (d.getVar("SPDX_NAMESPACE_PREFIX"), doc.name, str(uuid.uuid5(namespace_uuid, doc.name)))


def is_work_shared(d):
    pn = d.getVar('PN')
    return bb.data.inherits_class('kernel', d) or pn.startswith('gcc-source')


def convert_license_to_spdx(lic, d):
    def convert(l):
        if l == "&":
            return "AND"

        if l == "|":
            return "OR"

        spdx = d.getVarFlag('SPDXLICENSEMAP', l)
        if spdx is not None:
            return spdx

        return l

    return ' '.join(convert(l) for l in lic.split())


def process_sources(d):
    pn = d.getVar('PN')
    assume_provided = (d.getVar("ASSUME_PROVIDED") or "").split()
    if pn in assume_provided:
        for p in d.getVar("PROVIDES").split():
            if p != pn:
                pn = p
                break

    # glibc-locale: do_fetch, do_unpack and do_patch tasks have been deleted,
    # so avoid archiving source here.
    if pn.startswith('glibc-locale'):
        return False
    if d.getVar('PN') == "libtool-cross":
        return False
    if d.getVar('PN') == "libgcc-initial":
        return False
    if d.getVar('PN') == "shadow-sysroot":
        return False

    # We just archive gcc-source for all the gcc related recipes
    if d.getVar('BPN') in ['gcc', 'libgcc']:
        bb.debug(1, 'spdx: There is bug in scan of %s is, do nothing' % pn)
        return False

    return True


def write_doc(d, spdx_doc, subdir):
    from pathlib import Path

    spdx_deploy = Path(d.getVar("SPDXDEPLOY"))

    #dest = spdx_deploy / d.getVar("PACKAGE_ARCH") / (spdx_doc.name + ".spdx.json")
    dest = spdx_deploy / subdir / (spdx_doc.name + ".spdx.json")
    dest.parent.mkdir(exist_ok=True, parents=True)
    with dest.open("wb") as f:
        doc_sha1 = spdx_doc.to_json(f, sort_keys=True)

    l = spdx_deploy / "by-namespace" / spdx_doc.documentNamespace.replace('/', '_')
    l.parent.mkdir(exist_ok=True, parents=True)
    l.symlink_to(os.path.relpath(dest, l.parent))

    return doc_sha1


def read_doc(filename):
    import hashlib
    import spdx

    with filename.open("rb") as f:
        sha1 = hashlib.sha1()
        while True:
            chunk = f.read(4096)
            if not chunk:
                break
            sha1.update(chunk)

        f.seek(0)
        doc = spdx.SPDXDocument.from_json(f)

    return (doc, sha1.hexdigest())


def add_package_files(d, doc, spdx_pkg, topdir, get_spdxid, get_types, *, archive=None, ignore_dirs=[], ignore_top_level_dirs=[]):
    from pathlib import Path
    import spdx
    import hashlib

    source_date_epoch = d.getVar("SOURCE_DATE_EPOCH")

    sha1s = []
    spdx_files = []

    file_counter = 1
    for subdir, dirs, files in os.walk(topdir):
        dirs[:] = [d for d in dirs if d not in ignore_dirs]
        if subdir == str(topdir):
            dirs[:] = [d for d in dirs if d not in ignore_top_level_dirs]

        for file in files:
            filepath = Path(subdir) / file
            filename = str(filepath.relative_to(topdir))

            if filepath.is_file() and not filepath.is_symlink():
                spdx_file = spdx.SPDXFile()
                spdx_file.SPDXID = get_spdxid(file_counter)
                for t in get_types(filepath):
                    spdx_file.fileTypes.append(t)
                spdx_file.fileName = filename

                hashes = {
                    "SHA1": hashlib.sha1(),
                    "SHA256": hashlib.sha256(),
                }

                with filepath.open("rb") as f:
                    while True:
                        chunk = f.read(4096)
                        if not chunk:
                            break

                        for h in hashes.values():
                            h.update(chunk)

                    if archive is not None:
                        f.seek(0)
                        info = archive.gettarinfo(fileobj=f)
                        info.name = filename
                        info.uid = 0
                        info.gid = 0
                        info.uname = "root"
                        info.gname = "root"

                        if source_date_epoch is not None and info.mtime > int(source_date_epoch):
                            info.mtime = int(source_date_epoch)

                        archive.addfile(info, f)

                for k, v in hashes.items():
                    spdx_file.checksums.append(spdx.SPDXChecksum(
                        algorithm=k,
                        checksumValue=v.hexdigest(),
                    ))

                sha1s.append(hashes["SHA1"].hexdigest())

                doc.files.append(spdx_file)
                doc.add_relationship(spdx_pkg, "CONTAINS", spdx_file)
                spdx_pkg.hasFiles.append(spdx_file.SPDXID)

                spdx_files.append(spdx_file)

                file_counter += 1

    sha1s.sort()
    verifier = hashlib.sha1()
    for v in sha1s:
        verifier.update(v.encode("utf-8"))
    spdx_pkg.packageVerificationCode.packageVerificationCodeValue = verifier.hexdigest()

    return spdx_files


def add_package_sources_from_debug(d, package_doc, spdx_package, package, package_files, sources):
    from pathlib import Path
    import hashlib
    import oe.packagedata
    import spdx

    debug_search_paths = [
        Path(d.getVar('PKGD')),
        Path(d.getVar('STAGING_DIR_TARGET')),
        Path(d.getVar('STAGING_DIR_NATIVE')),
    ]

    pkg_data = oe.packagedata.read_subpkgdata_extended(package, d)

    if pkg_data is None:
        return

    for file_path, file_data in pkg_data["files_info"].items():
        if not "debugsrc" in file_data:
            continue

        for pkg_file in package_files:
            if file_path.lstrip("/") == pkg_file.fileName.lstrip("/"):
                break
        else:
            bb.fatal("No package file found for %s" % str(file_path))
            continue

        for debugsrc in file_data["debugsrc"]:
            for search in debug_search_paths:
                debugsrc_path = search / debugsrc.lstrip("/")
                if not debugsrc_path.exists():
                    continue

                with debugsrc_path.open("rb") as f:
                    sha = hashlib.sha256()
                    while True:
                        chunk = f.read(4096)
                        if not chunk:
                            break
                        sha.update(chunk)

                file_sha256 = sha.hexdigest()

                if not file_sha256 in sources:
                    bb.debug(1, "Debug source %s with SHA256 %s not found in any dependency" % (str(debugsrc_path), file_sha256))
                    continue

                source_file = sources[file_sha256]

                doc_ref = package_doc.find_external_document_ref(source_file.doc.documentNamespace)
                if doc_ref is None:
                    doc_ref = spdx.SPDXExternalDocumentRef()
                    doc_ref.externalDocumentId = "DocumentRef-dependency-" + source_file.doc.name
                    doc_ref.spdxDocument = source_file.doc.documentNamespace
                    doc_ref.checksum.algorithm = "SHA1"
                    doc_ref.checksum.checksumValue = source_file.doc_sha1
                    package_doc.externalDocumentRefs.append(doc_ref)

                package_doc.add_relationship(
                    pkg_file,
                    "GENERATED_FROM",
                    "%s:%s" % (doc_ref.externalDocumentId, source_file.file.SPDXID),
                    comment=debugsrc
                )
                break
            else:
                bb.debug(1, "Debug source %s not found" % debugsrc)


def collect_dep_recipes(d, doc, spdx_recipe):
    from pathlib import Path
    import sbom
    import spdx

    deploy_dir_spdx = Path(d.getVar("DEPLOY_DIR_SPDX"))

    dep_recipes = []
    taskdepdata = d.getVar("BB_TASKDEPDATA", False)
    deps = sorted(set(
        dep[0] for dep in taskdepdata.values() if
            dep[1] == "do_create_spdx" and dep[0] != d.getVar("PN")
    ))
    for dep_pn in deps:
        dep_recipe_path = deploy_dir_spdx / "recipes" / ("recipe-%s.spdx.json" % dep_pn)

        spdx_dep_doc, spdx_dep_sha1 = read_doc(dep_recipe_path)

        for pkg in spdx_dep_doc.packages:
            if pkg.name == dep_pn:
                spdx_dep_recipe = pkg
                break
        else:
            continue

        dep_recipes.append(sbom.DepRecipe(spdx_dep_doc, spdx_dep_sha1, spdx_dep_recipe))

        dep_recipe_ref = spdx.SPDXExternalDocumentRef()
        dep_recipe_ref.externalDocumentId = "DocumentRef-dependency-" + spdx_dep_doc.name
        dep_recipe_ref.spdxDocument = spdx_dep_doc.documentNamespace
        dep_recipe_ref.checksum.algorithm = "SHA1"
        dep_recipe_ref.checksum.checksumValue = spdx_dep_sha1

        doc.externalDocumentRefs.append(dep_recipe_ref)

        doc.add_relationship(
            "%s:%s" % (dep_recipe_ref.externalDocumentId, spdx_dep_recipe.SPDXID),
            "BUILD_DEPENDENCY_OF",
            spdx_recipe
        )

    return dep_recipes

collect_dep_recipes[vardepsexclude] += "BB_TASKDEPDATA"


def collect_dep_sources(d, dep_recipes):
    import sbom

    sources = {}
    for dep in dep_recipes:
        recipe_files = set(dep.recipe.hasFiles)

        for spdx_file in dep.doc.files:
            if spdx_file.SPDXID not in recipe_files:
                continue

            if "SOURCE" in spdx_file.fileTypes:
                for checksum in spdx_file.checksums:
                    if checksum.algorithm == "SHA256":
                        sources[checksum.checksumValue] = sbom.DepSource(dep.doc, dep.doc_sha1, dep.recipe, spdx_file)
                        break

    return sources


python do_create_spdx() {
    from datetime import datetime, timezone
    import sbom
    import spdx
    import uuid
    from pathlib import Path
    from contextlib import contextmanager

    @contextmanager
    def optional_tarfile(name, guard, mode="w"):
        import tarfile
        import bb.compress.zstd

        num_threads = int(d.getVar("BB_NUMBER_THREADS"))

        if guard:
            name.parent.mkdir(parents=True, exist_ok=True)
            with bb.compress.zstd.open(name, mode=mode + "b", num_threads=num_threads) as f:
                with tarfile.open(fileobj=f, mode=mode + "|") as tf:
                    yield tf
        else:
            yield None

    bb.build.exec_func("read_subpackage_metadata", d)

    deploy_dir_spdx = Path(d.getVar("DEPLOY_DIR_SPDX"))
    spdx_workdir = Path(d.getVar("SPDXWORK"))
    include_packaged = d.getVar("SPDX_INCLUDE_PACKAGED") == "1"
    include_sources = d.getVar("SPDX_INCLUDE_SOURCES") == "1"
    archive_sources = d.getVar("SPDX_ARCHIVE_SOURCES") == "1"
    archive_packaged = d.getVar("SPDX_ARCHIVE_PACKAGED") == "1"

    creation_time = datetime.now(tz=timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")

    doc = spdx.SPDXDocument()

    doc.name = "recipe-" + d.getVar("PN")
    doc.documentNamespace = get_doc_namespace(d, doc)
    doc.creationInfo.created = creation_time
    doc.creationInfo.comment = "This document was created by analyzing the source of the Yocto recipe during the build."
    doc.creationInfo.creators.append("Tool: meta-doubleopen")
    doc.creationInfo.creators.append("Organization: Double Open Project ()")
    doc.creationInfo.creators.append("Person: N/A ()")

    recipe = spdx.SPDXPackage()
    recipe.name = d.getVar("PN")
    recipe.versionInfo = d.getVar("PV")
    recipe.SPDXID = sbom.get_recipe_spdxid(d)

    src_uri = d.getVar('SRC_URI')
    if src_uri:
        recipe.downloadLocation = src_uri.split()[0]

    homepage = d.getVar("HOMEPAGE")
    if homepage:
        recipe.homepage = homepage

    license = d.getVar("LICENSE")
    if license:
        recipe.licenseDeclared = convert_license_to_spdx(license, d)

    summary = d.getVar("SUMMARY")
    if summary:
        recipe.summary = summary

    description = d.getVar("DESCRIPTION")
    if description:
        recipe.description = description

    # Some CVEs may be patched during the build process without incrementing the version number,
    # so querying for CVEs based on the CPE id can lead to false positives. To account for this,
    # save the CVEs fixed by patches to source information field in the SPDX.
    patched_cves = get_patched_cves(d)
    patched_cves = list(patched_cves)
    patched_cves = ' '.join(patched_cves)
    if patched_cves:
        recipe.sourceInfo = "CVEs fixed: " + patched_cves

    cpe_ids = get_cpe_ids(d)
    if cpe_ids:
        for cpe_id in cpe_ids:
            cpe = spdx.SPDXExternalReference()
            cpe.referenceCategory = "SECURITY"
            cpe.referenceType = "http://spdx.org/rdf/references/cpe23Type"
            cpe.referenceLocator = cpe_id
            recipe.externalRefs.append(cpe)

    doc.packages.append(recipe)
    doc.add_relationship(doc, "DESCRIBES", recipe)

    if process_sources(d) and include_sources:
        recipe_archive = deploy_dir_spdx / "recipes" / (doc.name + ".tar.zst")
        with optional_tarfile(recipe_archive, archive_sources) as archive:
            spdx_get_src(d)

            add_package_files(
                d,
                doc,
                recipe,
                spdx_workdir,
                lambda file_counter: "SPDXRef-SourceFile-%s-%d" % (d.getVar("PN"), file_counter),
                lambda filepath: ["SOURCE"],
                ignore_dirs=[".git"],
                ignore_top_level_dirs=["temp"],
                archive=archive,
            )

            if archive is not None:
                recipe.packageFileName = str(recipe_archive.name)

    dep_recipes = collect_dep_recipes(d, doc, recipe)

    doc_sha1 = write_doc(d, doc, "recipes")
    dep_recipes.append(sbom.DepRecipe(doc, doc_sha1, recipe))

    sources = collect_dep_sources(d, dep_recipes)

    pkgdest = Path(d.getVar("PKGDEST"))
    for package in d.getVar("PACKAGES").split():
        if not oe.packagedata.packaged(package, d):
            continue

        package_doc = spdx.SPDXDocument()
        pkg_name = d.getVar("PKG:%s" % package) or package
        package_doc.name = pkg_name
        package_doc.documentNamespace = get_doc_namespace(d, package_doc)
        package_doc.creationInfo.created = creation_time
        package_doc.creationInfo.comment = "This document was created by analyzing the source of the Yocto recipe during the build."
        package_doc.creationInfo.creators.append("Tool: meta-doubleopen")
        package_doc.creationInfo.creators.append("Organization: Double Open Project ()")
        package_doc.creationInfo.creators.append("Person: N/A ()")

        recipe_ref = spdx.SPDXExternalDocumentRef()
        recipe_ref.externalDocumentId = "DocumentRef-recipe"
        recipe_ref.spdxDocument = doc.documentNamespace
        recipe_ref.checksum.algorithm = "SHA1"
        recipe_ref.checksum.checksumValue = doc_sha1

        package_doc.externalDocumentRefs.append(recipe_ref)

        package_license = d.getVar("LICENSE:%s" % package) or d.getVar("LICENSE")

        spdx_package = spdx.SPDXPackage()

        spdx_package.SPDXID = sbom.get_package_spdxid(pkg_name)
        spdx_package.name = pkg_name
        spdx_package.versionInfo = d.getVar("PV")
        spdx_package.licenseDeclared = convert_license_to_spdx(package_license, d)

        package_doc.packages.append(spdx_package)

        package_doc.add_relationship(spdx_package, "GENERATED_FROM", "%s:%s" % (recipe_ref.externalDocumentId, recipe.SPDXID))
        package_doc.add_relationship(package_doc, "DESCRIBES", spdx_package)

        package_archive = deploy_dir_spdx / "packages" / (package_doc.name + ".tar.zst")
        with optional_tarfile(package_archive, archive_packaged) as archive:
            package_files = add_package_files(
                d,
                package_doc,
                spdx_package,
                pkgdest / package,
                lambda file_counter: sbom.get_packaged_file_spdxid(pkg_name, file_counter),
                lambda filepath: ["BINARY"],
                archive=archive,
            )

            if archive is not None:
                spdx_package.packageFileName = str(package_archive.name)

        add_package_sources_from_debug(d, package_doc, spdx_package, package, package_files, sources)

        write_doc(d, package_doc, "packages")
}
# NOTE: depending on do_unpack is a hack that is necessary to get it's dependencies for archive the source
addtask do_create_spdx after do_package do_packagedata do_unpack before do_build do_rm_work

SSTATETASKS += "do_create_spdx"
do_create_spdx[sstate-inputdirs] = "${SPDXDEPLOY}"
do_create_spdx[sstate-outputdirs] = "${DEPLOY_DIR_SPDX}"

python do_create_spdx_setscene () {
    sstate_setscene(d)
}
addtask do_create_spdx_setscene

do_create_spdx[dirs] = "${SPDXDEPLOY} ${SPDXWORK}"
do_create_spdx[cleandirs] = "${SPDXDEPLOY} ${SPDXWORK}"
do_create_spdx[depends] += "${PATCHDEPENDENCY}"
do_create_spdx[deptask] = "do_create_spdx"

def spdx_get_src(d):
    """
    save patched source of the recipe in SPDX_WORKDIR.
    """
    import shutil
    spdx_workdir = d.getVar('SPDXWORK')
    spdx_sysroot_native = d.getVar('STAGING_DIR_NATIVE')
    pn = d.getVar('PN')

    workdir = d.getVar("WORKDIR")

    try:
        # The kernel class functions require it to be on work-shared, so we dont change WORKDIR
        if not is_work_shared(d):
            # Change the WORKDIR to make do_unpack do_patch run in another dir.
            d.setVar('WORKDIR', spdx_workdir)
            # Restore the original path to recipe's native sysroot (it's relative to WORKDIR).
            d.setVar('STAGING_DIR_NATIVE', spdx_sysroot_native)

            # The changed 'WORKDIR' also caused 'B' changed, create dir 'B' for the
            # possibly requiring of the following tasks (such as some recipes's
            # do_patch required 'B' existed).
            bb.utils.mkdirhier(d.getVar('B'))

            bb.build.exec_func('do_unpack', d)
        # Copy source of kernel to spdx_workdir
        if is_work_shared(d):
            d.setVar('WORKDIR', spdx_workdir)
            d.setVar('STAGING_DIR_NATIVE', spdx_sysroot_native)
            src_dir = spdx_workdir + "/" + d.getVar('PN')+ "-" + d.getVar('PV') + "-" + d.getVar('PR')
            bb.utils.mkdirhier(src_dir)
            if bb.data.inherits_class('kernel',d):
                share_src = d.getVar('STAGING_KERNEL_DIR')
            cmd_copy_share = "cp -rf " + share_src + "/* " + src_dir + "/"
            cmd_copy_kernel_result = os.popen(cmd_copy_share).read()
            bb.note("cmd_copy_kernel_result = " + cmd_copy_kernel_result)

            git_path = src_dir + "/.git"
            if os.path.exists(git_path):
                shutils.rmtree(git_path)

        # Make sure gcc and kernel sources are patched only once
        if not (d.getVar('SRC_URI') == "" or is_work_shared(d)):
            bb.build.exec_func('do_patch', d)

        # Some userland has no source.
        if not os.path.exists( spdx_workdir ):
            bb.utils.mkdirhier(spdx_workdir)
    finally:
        d.setVar("WORKDIR", workdir)

do_rootfs[recrdeptask] += "do_create_spdx"

ROOTFS_POSTUNINSTALL_COMMAND =+ "image_combine_spdx ; "
python image_combine_spdx() {
    import os
    import spdx
    import sbom
    from oe.rootfs import image_list_installed_packages
    from datetime import timezone, datetime
    from pathlib import Path
    import tarfile
    import bb.compress.zstd

    creation_time = datetime.now(tz=timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    image_name = d.getVar("IMAGE_NAME")
    image_link_name = d.getVar("IMAGE_LINK_NAME")

    deploy_dir_spdx = Path(d.getVar("DEPLOY_DIR_SPDX"))
    imgdeploydir = Path(d.getVar("IMGDEPLOYDIR"))
    source_date_epoch = d.getVar("SOURCE_DATE_EPOCH")

    doc = spdx.SPDXDocument()
    doc.name = image_name
    doc.documentNamespace = get_doc_namespace(d, doc)
    doc.creationInfo.created = creation_time
    doc.creationInfo.comment = "This document was created by analyzing the source of the Yocto recipe during the build."
    doc.creationInfo.creators.append("Tool: meta-doubleopen")
    doc.creationInfo.creators.append("Organization: Double Open Project ()")
    doc.creationInfo.creators.append("Person: N/A ()")

    image = spdx.SPDXPackage()
    image.name = d.getVar("PN")
    image.versionInfo = d.getVar("PV")
    image.SPDXID = sbom.get_image_spdxid(image_name)

    doc.packages.append(image)

    spdx_package = spdx.SPDXPackage()

    packages = image_list_installed_packages(d)

    for name in sorted(packages.keys()):
        pkg_spdx_path = deploy_dir_spdx / "packages" / (name + ".spdx.json")
        pkg_doc, pkg_doc_sha1 = read_doc(pkg_spdx_path)

        for p in pkg_doc.packages:
            if p.name == name:
                pkg_ref = spdx.SPDXExternalDocumentRef()
                pkg_ref.externalDocumentId = "DocumentRef-%s" % pkg_doc.name
                pkg_ref.spdxDocument = pkg_doc.documentNamespace
                pkg_ref.checksum.algorithm = "SHA1"
                pkg_ref.checksum.checksumValue = pkg_doc_sha1

                doc.externalDocumentRefs.append(pkg_ref)
                doc.add_relationship(image, "CONTAINS", "%s:%s" % (pkg_ref.externalDocumentId, p.SPDXID))
                break
        else:
            bb.fatal("Unable to find package with name '%s' in SPDX file %s" % (name, pkg_spdx_path))

    image_spdx_path = imgdeploydir / (image_name + ".spdx.json")

    with image_spdx_path.open("wb") as f:
        doc.to_json(f, sort_keys=True)

    image_spdx_link = imgdeploydir / (image_link_name + ".spdx.json")
    image_spdx_link.symlink_to(os.path.relpath(image_spdx_path, image_spdx_link.parent))

    num_threads = int(d.getVar("BB_NUMBER_THREADS"))

    visited_docs = set()

    spdx_tar_path = imgdeploydir / (image_name + ".spdx.tar.zst")
    with bb.compress.zstd.open(spdx_tar_path, "w", num_threads=num_threads) as f:
        with tarfile.open(fileobj=f, mode="w|") as tar:
            def collect_spdx_document(path):
                nonlocal tar
                nonlocal deploy_dir_spdx
                nonlocal source_date_epoch

                if path in visited_docs:
                    return

                visited_docs.add(path)

                with path.open("rb") as f:
                    doc = spdx.SPDXDocument.from_json(f)
                    f.seek(0)

                    if doc.documentNamespace in visited_docs:
                        return

                    bb.note("Adding SPDX document %s" % path)
                    visited_docs.add(doc.documentNamespace)
                    info = tar.gettarinfo(fileobj=f)

                    info.name = doc.name + ".spdx.json"
                    info.uid = 0
                    info.gid = 0
                    info.uname = "root"
                    info.gname = "root"

                    if source_date_epoch is not None and info.mtime > int(source_date_epoch):
                        info.mtime = int(source_date_epoch)

                    tar.addfile(info, f)

                for ref in doc.externalDocumentRefs:
                    ref_path = deploy_dir_spdx / "by-namespace" / ref.spdxDocument.replace("/", "_")
                    collect_spdx_document(ref_path)

            collect_spdx_document(image_spdx_path)

    spdx_tar_link = imgdeploydir / (image_link_name + ".spdx.tar.zst")
    spdx_tar_link.symlink_to(os.path.relpath(spdx_tar_path, spdx_tar_link.parent))
}


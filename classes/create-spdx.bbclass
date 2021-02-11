inherit doubleopen-common
inherit cve-data


SPDX_DEPLOY_DIR ??= "${DEPLOY_DIR}/spdx"
SPDX_TOPDIR ?= "${WORKDIR}/spdx_sstate_dir"
SPDX_OUTDIR ?= "${SPDX_TOPDIR}/${TARGET_SYS}/${PF}/"
SPDX_WORKDIR ?= "${WORKDIR}/spdx_temp/"

SPDX_EXCLUDE_NATIVE ??= "1"
SPDX_EXCLUDE_SDK ??= "1"
SPDX_EXCLUDE_PACKAGES ??= ""

do_write_spdx[dirs] = "${WORKDIR}"

python do_create_spdx() {
    """
    Write SPDX information of the package to an SPDX JSON document.
    """
    import os
    from datetime import datetime, timezone
    import uuid

    if bb.data.inherits_class('nopackages', d):
        return

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
        return
    if (d.getVar('PN') == "libtool-cross"):
        return
    if (d.getVar('PN') == "libgcc-initial"):
        return
    if (d.getVar('PN') == "shadow-sysroot"):
        return

    # We just archive gcc-source for all the gcc related recipes
    if d.getVar('BPN') in ['gcc', 'libgcc']:
        bb.debug(1, 'spdx: There is bug in scan of %s is, do nothing' % pn)
        return

    spdx_outdir = d.getVar('SPDX_OUTDIR')
    spdx_workdir = d.getVar('SPDX_WORKDIR')
    spdx_temp_dir = os.path.join(spdx_workdir, "temp")
    temp_dir = os.path.join(d.getVar('WORKDIR'), "temp")

    manifest_dir = (d.getVar('SPDX_DEPLOY_DIR') or "")
    if not os.path.exists( manifest_dir ):
        bb.utils.mkdirhier( manifest_dir )

    import json
    pkgdatadir = d.getVar('PKGDESTWORK')
    source_location = d.getVar('S')
    workdir = d.getVar('WORKDIR')
    data_file = manifest_dir + d.expand("/${PF}")

    # Create SPDX for the package
    spdx = {}

    # Document Creation information
    spdx["spdxVersion"] = "SPDX-2.2"
    spdx["dataLicense"] = "CC0-1.0"
    spdx["SPDXID"] = "SPDXRef-" + d.getVar("PF")
    spdx["name"] = d.getVar("PF")
    spdx["documentNamespace"] = "http://spdx.org/spdxdocs/" + spdx["name"] + str(uuid.uuid4())
    spdx["creationInfo"] = {}
    creation_time = datetime.now(tz=timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    spdx["creationInfo"]["created"] = creation_time
    spdx["creationInfo"]["licenseListVersion"] = "3.11"
    spdx["creationInfo"]["comment"] = "This document was created by analyzing the source of the Yocto recipe during the build."
    spdx["creationInfo"]["creators"] = ["Tool: meta-doubleopen", "Organization: Double Open Project ()", "Person: N/A ()"]

    # Package Information
    recipe_package = {}
    recipe_package["name"] = d.getVar('PN')
    recipe_package["SPDXID"] = "SPDXRef-Package-Recipe-" + d.getVar('PN')
    recipe_package["version"] = d.getVar('PV')
    package_download_location = (d.getVar('SRC_URI', True) or "")
    if package_download_location != "":
        package_download_location = package_download_location.split()[0]
    recipe_package["downloadLocation"] = package_download_location
    package_homepage = (d.getVar('HOMEPAGE', True) or "")
    recipe_package["homepage"] = package_homepage
    recipe_package["licenseConcluded"] = "NOASSERTION"
    recipe_package["licenseInfoFromFiles"] = ["NOASSERTION"]
    licenses = d.getVar("LICENSE")
    if licenses:
        recipe_package["licenseDeclared"] = licenses
    else:
        recipe_package["licenseDeclared"] = "NOASSERTION"
    package_summary = (d.getVar('SUMMARY', True) or "")
    recipe_package["summary"] = package_summary
    description = d.getVar('DESCRIPTION')
    if description:
        recipe_package["description"] = description

    cpe_ids = get_cpe_ids(d)
    recipe_package["externalRefs"] = []

    if cpe_ids:
        for cpe_id in cpe_ids:
            cpe = {}
            cpe["referenceCategory"] = "SECURITY"
            cpe["referenceType"] = "http://spdx.org/rdf/references/cpe23Type"
            cpe["referenceLocator"] = cpe_id
            recipe_package["externalRefs"].append(cpe)


    # Some CVEs may be patched during the build process without incrementing the version number,
    # so querying for CVEs based on the CPE id can lead to false positives. To account for this,
    # save the CVEs fixed by patches to source information field in the SPDX.
    patched_cves = get_patched_cves(d)
    patched_cves = list(patched_cves)
    patched_cves = ' '.join(patched_cves)
    if patched_cves:
        recipe_package["sourceInfo"] = "CVEs fixed: " + patched_cves

    # Get and patch the source for the recipe
    spdx_get_src(d)

    spdx["packages"] = [recipe_package]

    spdx['files'] = []
    spdx["relationships"] = []

    ignore_dirs = [".git"]
    # Yocto creates temp directory for logs etc in the top level of the workdir. We want to ignore
    # it but include directories named temp deeper in the source.
    ignore_top_level_dirs = ["temp"]

    # Iterate over files in the recipe's source and create SPDX file objects for them.
    source_file_counter = 1
    for subdir, dirs, files in os.walk(spdx_workdir):
        dirs[:] = [d for d in dirs if d not in ignore_dirs]
        if subdir == spdx_workdir:
            dirs[:] = [d for d in dirs if d not in ignore_top_level_dirs]
        for file in files:
            filepath = os.path.join(subdir,file)
            if os.path.exists(filepath):
                spdx_file = {}
                spdx_file["SPDXID"] = "SPDXRef-SourceFile-" + recipe_package["name"] + "-" + str(source_file_counter)
                source_file_counter += 1
                spdx_file["checksums"] = []
                file_sha256 = {}
                file_sha256["algorithm"] = "SHA256"
                file_sha256["checksumValue"] = sha256(filepath)
                file_sha1 = {}
                file_sha1["algorithm"] = "SHA1"
                file_sha1["checksumValue"] = sha1(filepath)
                spdx_file["checksums"].append(file_sha256)
                spdx_file["checksums"].append(file_sha1)
                filename = os.path.relpath(os.path.join(subdir, file), spdx_workdir)
                spdx_file["fileName"] = filename
                spdx_file["licenseConcluded"] = "NOASSERTION"
                spdx_file["licenseInfoInFiles"] = ["NOASSERTION"]
                spdx_file["copyrightText"] = "NOASSERTION"

                # All files in the source of the recipe are marked as SOURCE.
                spdx_file["fileTypes"] = ["SOURCE"]

                spdx['files'].append(spdx_file)

                relationship = {}
                relationship["spdxElementId"] = recipe_package["SPDXID"]
                relationship["relatedSpdxElement"] = spdx_file["SPDXID"]
                relationship["relationshipType"] = "CONTAINS"
                spdx["relationships"].append(relationship)

    # Change workdir back to get correct PKGD.
    d.setVar("WORKDIR", workdir)
    output_dir = d.getVar("PKGD")

    output_files = []
    ignore_dirs = ["temp", ".git"]

    # Create packages for all sub-packages that the recipe creates.
    packages = d.getVar('PACKAGES')

    # Yocto splits the packages to PKGDEST, where we can get the binaries of each sub-package from
    # PKGDEST/name.
    packages_split = d.getVar("PKGDEST")
    for package in packages.split():
        spdx_package = {}
        spdx_package["name"] = package
        spdx_package["SPDXID"] = "SPDXRef-Package-" + package
        spdx_package["version"] = d.getVar('PV')
        spdx["packages"].append(spdx_package)

        package_relationship = {}
        package_relationship["spdxElementId"] = recipe_package["SPDXID"]
        package_relationship["relatedSpdxElement"] = spdx_package["SPDXID"]
        package_relationship["relationshipType"] = "PACKAGE_OF"
        spdx["relationships"].append(package_relationship)

        directory = os.path.join(packages_split, package)
        binary_file_counter = 1
        for subdir, dirs, files in os.walk(directory, followlinks=True):
            if subdir == directory:
                dirs[:] = [d for d in dirs if d not in ignore_dirs]
            for file in files:
                filepath = os.path.join(subdir, file)
                if os.path.exists(filepath):
                    spdx_file = {}
                    spdx_file["SPDXID"] = "SPDXRef-BinaryFile-" + recipe_package["name"] + "-" + str(binary_file_counter)
                    binary_file_counter += 1
                    spdx_file["checksums"] = []
                    file_sha256 = {}
                    file_sha256["algorithm"] = "SHA256"
                    file_sha256["checksumValue"] = sha256(filepath)
                    file_sha1 = {}
                    file_sha1["algorithm"] = "SHA1"
                    file_sha1["checksumValue"] = sha1(filepath)
                    spdx_file["checksums"].append(file_sha256)
                    spdx_file["checksums"].append(file_sha1)
                    filename = os.path.relpath(os.path.join(subdir, file), directory)
                    spdx_file["fileName"] = filename
                    spdx_file["licenseConcluded"] = "NOASSERTION"
                    spdx_file["licenseInfoInFiles"] = ["NOASSERTION"]
                    spdx_file["copyrightText"] = "NOASSERTION"
                
                    # All deployed files of the package are marked as BINARY.
                    spdx_file["fileTypes"] = ["BINARY"]

                    relationship = {}
                    relationship["spdxElementId"] = spdx_package["SPDXID"]
                    relationship["relatedSpdxElement"] = spdx_file["SPDXID"]
                    relationship["relationshipType"] = "CONTAINS"

                    spdx["relationships"].append(relationship)
                    spdx["files"].append(spdx_file)

                    output_files.append(spdx_file)

    tar_name = spdx_create_tarball(d, spdx_workdir, manifest_dir)
    
    # Save SPDX for the package in pkgdata.
    with open(data_file + ".spdx.json", 'w') as f:
        f.write(json.dumps(spdx))
}


def spdx_get_src(d):
    """
    save patched source of the recipe in SPDX_WORKDIR.
    """
    import shutil
    spdx_workdir = d.getVar('SPDX_WORKDIR')
    spdx_sysroot_native = d.getVar('STAGING_DIR_NATIVE')
    pn = d.getVar('PN')
    
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
            remove_dir_tree(git_path)

    # Make sure gcc and kernel sources are patched only once
    if not (d.getVar('SRC_URI') == "" or is_work_shared(d)):
        bb.build.exec_func('do_patch', d)

    # Some userland has no source.
    if not os.path.exists( spdx_workdir ):
        bb.utils.mkdirhier(spdx_workdir)

addtask do_create_spdx after do_install before do_build
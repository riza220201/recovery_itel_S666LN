#!/usr/bin/env python3
"""repack-img.py <donor-vendor_boot.img> <recovery-fragment.lz4> <out.img>

Build the flashable 64 MiB vendor_boot image: the DONOR's header, dtb and
PLATFORM ramdisk fragment, with only the RECOVERY fragment replaced.

WHY THIS SCRIPT EXISTS
======================
The .img route was previously done by hand, and the README's own warning came
true once already: it "pins the platform fragment to that donor's", and the
donor in use was three ROM builds out of date (see tools/package-pbrp.sh).
Hand-assembly is also where the "PBRP's own platform fragment is four bytes"
mistake lives -- flash that and you get a touch UI with no touch input, because
the platform fragment carries the kernel modules, the four touch firmware blobs
and the patched adaptive-ts.ko.

PREFER THE ZIP (tools/package-pbrp.sh). It swaps the fragment on the device,
against the vendor_boot actually installed, so it cannot go stale and it writes
both slots. This .img exists for one case the zip cannot serve: a device whose
PBRP has already been replaced by a ROM's own recovery, which must be recovered
over fastboot.

  DONOR = the vendor_boot.img of the LATEST ROM BUILD, taken from that build's
  own *-signed-images.zip. Not a previous PBRP .img, and not the device.

WHY THE HEADER IS COPIED VERBATIM
=================================
Reconstructing a v4 header field by field risks silently dropping something --
reserved words, or the 16-byte board_id array that follows the name in every
table entry. Copying the donor's header page and patching only
vendor_ramdisk_size plus the two table entries' size/offset is the smallest
change that can do the job, and it is *provable*: see the mandatory self-test.

THE SELF-TEST IS NOT OPTIONAL
=============================
Before producing anything, this repacks the donor with the donor's OWN recovery
fragment and asserts the result is byte-identical to the donor. If the packing
logic is wrong in any way that matters, that assertion fails and nothing is
written. Proven against the 03/09 release: reproduced it byte for byte, AVB
footer included.

AVB
===
The footer is Algorithm NONE -- a hash, not a signature -- so it is
reproducible. Salt and the fingerprint property are read OFF THE DONOR rather
than hardcoded, because they belong to the ROM build, and the fingerprint is
the identity this project pins (BLUEPRINT section 4: it must stay rev 28).
Run avbtool add_hash_footer afterwards; this script prints the exact command.
"""
import struct, sys, hashlib, subprocess, os

HDR_VRS_OFF = 0x18
TYPE_PLATFORM, TYPE_RECOVERY = 1, 2


def pg(x, ps):
    return (x + ps - 1) // ps * ps


def _layout(d):
    assert d[0:8] == b'VNDRBOOT', 'not a vendor_boot image'
    hv, ps, _ka, _ra, vrs = struct.unpack('<IIIII', d[8:28])
    assert hv == 4, 'only vendor_boot v4 is handled, got v%d' % hv
    o = 28 + 2048 + 4 + 16
    hdr_size, dtb_size = struct.unpack('<II', d[o:o + 8])
    o += 8 + 8
    vrt_size, vrt_n, vrt_es, bc_size = struct.unpack('<IIII', d[o:o + 16])
    p = pg(hdr_size, ps); vr = p
    p += pg(vrs, ps);     dtb = p
    p += pg(dtb_size, ps); vrt = p
    p += pg(vrt_size, ps); bc = p
    return dict(ps=ps, vrs=vrs, hdr_size=hdr_size, dtb_size=dtb_size,
                vrt_size=vrt_size, vrt_n=vrt_n, vrt_es=vrt_es, bc_size=bc_size,
                vr=vr, dtb=dtb, vrt=vrt, bc=bc)


def repack(donor_bytes, new_recovery):
    d, L = donor_bytes, _layout(donor_bytes)
    ps, vr, vrt, es, n = L['ps'], L['vr'], L['vrt'], L['vrt_es'], L['vrt_n']
    assert n == 2, 'expected 2 fragments (platform + recovery), got %d' % n

    ents, meta = [], []
    for i in range(n):
        e = bytearray(d[vrt + i * es: vrt + (i + 1) * es])
        sz, of, ty = struct.unpack('<III', bytes(e[:12]))
        ents.append(e); meta.append((sz, of, ty))

    # By TYPE, never by index -- fragment order is not guaranteed by the spec.
    plat_i = next(i for i, m in enumerate(meta) if m[2] == TYPE_PLATFORM)
    rec_i = next(i for i, m in enumerate(meta) if m[2] == TYPE_RECOVERY)

    plat = d[vr + meta[plat_i][1]: vr + meta[plat_i][1] + meta[plat_i][0]]
    # The four-byte-platform-fragment mistake in another costume.
    assert len(plat) > 1_000_000, (
        'donor platform fragment is only %d B -- that is a PBRP-built '
        'vendor_boot, not a ROM one. Flashing it gives touch with no input.'
        % len(plat))

    section = b''
    for i in sorted(range(n), key=lambda k: meta[k][1]):
        data = new_recovery if i == rec_i else plat
        struct.pack_into('<I', ents[i], 4, len(section))
        struct.pack_into('<I', ents[i], 0, len(data))
        section += data

    hdr = bytearray(d[:pg(L['hdr_size'], ps)])
    struct.pack_into('<I', hdr, HDR_VRS_OFF, len(section))

    out = bytes(hdr)
    out += section.ljust(pg(len(section), ps), b'\0')
    out += d[L['dtb']:L['dtb'] + L['dtb_size']].ljust(pg(L['dtb_size'], ps), b'\0')
    out += b''.join(bytes(e) for e in ents).ljust(pg(L['vrt_size'], ps), b'\0')
    if L['bc_size']:
        out += d[L['bc']:L['bc'] + L['bc_size']].ljust(pg(L['bc_size'], ps), b'\0')
    return out, plat, meta[rec_i]


def donor_recovery_fragment(d):
    L = _layout(d)
    for i in range(L['vrt_n']):
        e = d[L['vrt'] + i * L['vrt_es']: L['vrt'] + (i + 1) * L['vrt_es']]
        sz, of, ty = struct.unpack('<III', e[:12])
        if ty == TYPE_RECOVERY:
            return d[L['vr'] + of: L['vr'] + of + sz]
    raise SystemExit('!! donor has no recovery fragment')


def avb_params(path):
    """Read salt and the fingerprint prop off the donor, do not hardcode them."""
    here = os.path.dirname(os.path.abspath(__file__))
    for cand in (os.environ.get('AVBTOOL'),
                 '/mnt/external_nvme/pbrp/external/avb/avbtool.py'):
        if cand and os.path.exists(cand):
            avbtool = cand
            break
    else:
        return None, None, None
    try:
        out = subprocess.run([sys.executable, avbtool, 'info_image',
                              '--image', path], capture_output=True,
                             text=True, timeout=120).stdout
    except Exception:
        return avbtool, None, None
    salt = fp = None
    for line in out.splitlines():
        s = line.strip()
        if s.startswith('Salt:'):
            salt = s.split(None, 1)[1]
        if 'vendor_boot.fingerprint ->' in s:
            fp = s.split('->', 1)[1].strip().strip("'")
    return avbtool, salt, fp


def main():
    if len(sys.argv) != 4:
        raise SystemExit(__doc__)
    donor_path, frag_path, out_path = sys.argv[1:4]
    donor = open(donor_path, 'rb').read()
    newfrag = open(frag_path, 'rb').read()
    assert len(newfrag) > 1_000_000, (
        '%s is only %d B -- that is not a recovery ramdisk' % (frag_path, len(newfrag)))

    # ---- mandatory self-test: donor + donor's own fragment == donor
    control, _, _ = repack(donor, donor_recovery_fragment(donor))
    orig = donor[:len(control)]
    if control != orig:
        raise SystemExit('!! SELF-TEST FAILED: repacking the donor with its own '
                         'recovery fragment did not reproduce it. Refusing to '
                         'write anything.')
    print('== self-test OK: donor round-trips byte-for-byte (%d bytes)' % len(control))

    out, plat, recmeta = repack(donor, newfrag)
    print('   donor            %s' % donor_path)
    print('   platform frag    %d bytes  sha256 %s  (KEPT)'
          % (len(plat), hashlib.sha256(plat).hexdigest()[:16]))
    print('   recovery frag    %d bytes  sha256 %s  (NEW, was %d)'
          % (len(newfrag), hashlib.sha256(newfrag).hexdigest()[:16], recmeta[0]))
    open(out_path, 'wb').write(out)
    print('== wrote %s  %d bytes, NO AVB FOOTER YET' % (out_path, len(out)))

    avbtool, salt, fp = avb_params(donor_path)
    print('\n== now add the footer (parameters read off the donor):')
    if avbtool and salt and fp:
        print("   python3 %s add_hash_footer \\\n"
              "     --image %s \\\n"
              "     --partition_name vendor_boot --partition_size 67108864 \\\n"
              "     --salt %s \\\n"
              "     --algorithm NONE \\\n"
              "     --prop 'com.android.build.vendor_boot.fingerprint:%s'"
              % (avbtool, out_path, salt, fp))
    else:
        print('   !! could not read AVB params from the donor; set AVBTOOL= and rerun,')
        print('      or read them with `avbtool info_image --image <donor>`.')


if __name__ == '__main__':
    main()

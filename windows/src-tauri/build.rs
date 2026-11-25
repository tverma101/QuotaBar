fn main() {
    let mut attributes = tauri_build::Attributes::new();
    if std::env::var("CARGO_CFG_TARGET_OS").as_deref() == Ok("windows") {
        attributes = attributes.windows_attributes(
            tauri_build::WindowsAttributes::new_without_app_manifest(),
        );
        println!("cargo:rerun-if-changed=common-controls.rc");
        println!("cargo:rerun-if-changed=common-controls.manifest");
        embed_resource::compile_for_everything("common-controls.rc", embed_resource::NONE)
            .manifest_required()
            .expect("failed to embed the Windows Common Controls manifest");
    }
    tauri_build::try_build(attributes).expect("failed to build Tauri resources");
}

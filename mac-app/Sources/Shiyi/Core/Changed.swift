import Combine

/// 只在「值真的变了」时才通知界面刷新的 `@Published` 替代品。
///
/// `@Published` 每次赋值都会触发 `objectWillChange`（哪怕新旧值一样），而 `AppModel` 是整个界面共用的一个对象：
/// 每次触发，所有显示中的页面和每一行待办都要重新求值。加载标志（`xxxLoading = false`）、错误提示、
/// 「读回来的数据和原来一样」这类赋值非常多，编辑 / 删除一个待办后会连着触发七八次，CPU 就是这样冲高的。
/// 用它代替后，值不变的赋值不再刷新界面。
@propertyWrapper
struct Changed<Value: Equatable> {
    private var stored: Value

    init(wrappedValue: Value) { stored = wrappedValue }

    @available(*, unavailable, message: "只能用在 ObservableObject 的属性上")
    var wrappedValue: Value {
        get { fatalError() }
        set { fatalError() }
    }

    static subscript<T: ObservableObject>(
        _enclosingInstance instance: T,
        wrapped wrappedKeyPath: ReferenceWritableKeyPath<T, Value>,
        storage storageKeyPath: ReferenceWritableKeyPath<T, Changed>
    ) -> Value where T.ObjectWillChangePublisher == ObservableObjectPublisher {
        get { instance[keyPath: storageKeyPath].stored }
        set {
            guard instance[keyPath: storageKeyPath].stored != newValue else { return }
            instance.objectWillChange.send()
            instance[keyPath: storageKeyPath].stored = newValue
        }
    }
}

extension Changed where Value: ExpressibleByNilLiteral {
    init() { stored = nil }
}
